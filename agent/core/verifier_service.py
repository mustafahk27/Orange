from __future__ import annotations

from difflib import SequenceMatcher
import re

from core.config import SCHEMA_VERSION_CURRENT
from core.schemas import VerifyRequest, VerifyResponse


class VerifierService:
    """Deterministic verifier baseline with corrective hints."""

    def verify(self, request: VerifyRequest) -> VerifyResponse:
        before_context = (request.before_context or "").strip()
        after_context = (request.after_context or "").strip()
        delta_score = self._context_delta(before_context, after_context)
        no_progress_reason: str | None = None

        loop_context = request.loop_context
        current_state = self._coerce_state(loop_context.current_state if loop_context else None)
        expected_next_state = self._coerce_state(loop_context.next_required_state if loop_context else None)
        observed_state = self._infer_state_from_context(before_context, after_context, request.action_plan.actions)

        state_transition = self._infer_state_transition(request.action_plan.actions)
        state_reason = self._state_reason(
            before_context=before_context,
            after_context=after_context,
            previous_state=current_state,
            observed_state=observed_state,
            execution_result=request.execution_result,
            delta_score=delta_score,
            expected_next_state=expected_next_state,
            first_action_kind=request.action_plan.actions[0].kind if request.action_plan.actions else None,
        )

        if request.execution_result == "success" and not self._is_noop_open_or_redundant(
            request=request,
            before_context=before_context,
            after_context=after_context,
            delta_score=delta_score,
        ):
            expected_advance = self._is_transition_sufficient(
                expected_next_state=expected_next_state,
                observed_state=observed_state,
                previous_state=current_state,
            )

            if not expected_advance:
                no_progress_reason = (
                    f"Expected state transition to '{expected_next_state}' but observed '{observed_state}'"
                )
            elif (
                observed_state == current_state
                and delta_score < 0.01
                and not (expected_next_state == "COMPLETED" and observed_state == "COMMIT_ATTEMPTED")
            ):
                no_progress_reason = (
                    f"No meaningful state transition after success from {current_state or 'UNKNOWN'} "
                    f"to {observed_state or 'UNKNOWN'}"
                )
            elif loop_context is None and delta_score < 0.01 and request.before_context and request.after_context:
                no_progress_reason = (
                    f"No meaningful UI/context delta detected after success ({delta_score:.2f})"
                )

        if no_progress_reason is None and request.execution_result == "success":
            if self._is_noop_open_or_redundant(
                request=request,
                before_context=before_context,
                after_context=after_context,
                delta_score=delta_score,
            ):
                no_progress_reason = "Open-app action did not change active app or window"

        corrective_actions = []
        if request.execution_result in {"failure", "partial"} and request.action_plan.actions:
            corrective_actions = self._build_corrective_suffix(
                actions=request.action_plan.actions,
                failed_action_id=request.failed_action_id,
                completed_actions=request.completed_actions,
                skip_first_open_app=False,
            )

        if no_progress_reason is None and request.execution_result == "success":
            return VerifyResponse(
                schema_version=SCHEMA_VERSION_CURRENT,
                session_id=request.session_id,
                status="success",
                confidence=0.9 if delta_score > 0.05 else 0.75,
                reason=f"Execution reported success with context delta {delta_score:.2f}",
                state=observed_state,
                required_transition=state_transition,
                state_reason=state_reason,
                corrective_actions=corrective_actions,
            )

        return VerifyResponse(
            schema_version=SCHEMA_VERSION_CURRENT,
            session_id=request.session_id,
            status="failure",
            confidence=0.55 if request.execution_result != "success" else 0.45,
            reason=no_progress_reason or request.reason or self._default_failure_reason(request.execution_result, delta_score),
            state=observed_state,
            required_transition=state_transition,
            state_reason=state_reason,
            corrective_actions=corrective_actions,
        )

    @staticmethod
    def _build_corrective_suffix(
        *,
        actions: list,
        failed_action_id: str | None,
        completed_actions: list[str],
        skip_first_open_app: bool,
    ) -> list:
        if not actions:
            return []

        start_index = len(actions) - 1
        by_id = {action.id: idx for idx, action in enumerate(actions)}

        if failed_action_id and failed_action_id in by_id:
            start_index = by_id[failed_action_id]
        elif completed_actions:
            completed_set = set(completed_actions)
            first_pending = next((idx for idx, action in enumerate(actions) if action.id not in completed_set), None)
            if first_pending is not None:
                start_index = first_pending

        if skip_first_open_app and actions:
            if actions[0].kind == "open_app":
                start_index = max(1, start_index)

        if start_index >= len(actions):
            return []

        suffix = actions[start_index : start_index + 3]
        return [action.model_copy(update={"id": f"retry_{idx}"}) for idx, action in enumerate(suffix, start=1)]

    @staticmethod
    def _parse_context_field(context: str, field: str) -> str | None:
        match = re.search(rf"{re.escape(field)}=(.*?)(?:, [a-z_]+=[^,]*|$)", context)
        if not match:
            return None
        return match.group(1).strip()

    @classmethod
    def _is_noop_open_or_redundant(
        cls,
        *,
        request: VerifyRequest,
        before_context: str,
        after_context: str,
        delta_score: float,
    ) -> bool:
        if request.execution_result != "success":
            return False
        if not request.action_plan.actions:
            return False

        first_action = request.action_plan.actions[0]
        if first_action.kind != "open_app":
            if delta_score >= 0.01:
                return False
            if first_action.kind in {"click", "double_click", "select_menu_item"} and request.reason:
                return True
            return False

        target = (first_action.target or first_action.app_bundle_id or "").strip().lower()
        if not target:
            return False

        before_app = (cls._parse_context_field(before_context, "app") or "").lower()
        after_app = (cls._parse_context_field(after_context, "app") or "").lower()
        before_window = (cls._parse_context_field(before_context, "window") or "").lower()
        after_window = (cls._parse_context_field(after_context, "window") or "").lower()
        if not before_app or not after_app:
            return False

        if target not in before_app and target not in after_app:
            return False
        return before_app == after_app and before_window == after_window

    @staticmethod
    def _context_delta(before: str, after: str) -> float:
        if not before and not after:
            return 0.0
        if before and not after:
            return 0.0
        if not before and after:
            return 1.0
        ratio = SequenceMatcher(a=before, b=after).ratio()
        return max(0.0, 1.0 - ratio)

    @staticmethod
    def _coerce_state(raw_state: str | None) -> str | None:
        if not raw_state:
            return None
        if raw_state in {
            "APP_ACTIVE",
            "UI_CONTEXT_CHANGED",
            "EDITOR_OPEN",
            "FIELD_FOCUSED",
            "DATA_ENTERED",
            "COMMIT_ATTEMPTED",
            "COMPLETED",
            "BLOCKED",
        }:
            return raw_state
        return None

    @staticmethod
    def _infer_state_from_context(before_context: str, after_context: str, actions: list) -> str | None:
        before_app = (VerifierService._parse_context_field(before_context, "app") or "").lower()
        after_app = (VerifierService._parse_context_field(after_context, "app") or "").lower()
        before_window = (VerifierService._parse_context_field(before_context, "window") or "").lower()
        after_window = (VerifierService._parse_context_field(after_context, "window") or "").lower()

        if after_app and before_app and after_app != before_app:
            return "APP_ACTIVE"
        if after_window and before_window and after_window != before_window:
            return "UI_CONTEXT_CHANGED"

        kinds = {action.kind for action in actions}
        if "type" in kinds:
            return "DATA_ENTERED"
        if any(
            action.kind == "key_combo" and VerifierService._is_commit_key_combo(action.key_combo)
            for action in actions
        ):
            return "COMMIT_ATTEMPTED"

        return "APP_ACTIVE"

    @staticmethod
    def _infer_state_transition(actions: list) -> str:
        if not actions:
            return "APP_ACTIVE"

        kinds = {action.kind for action in actions}
        if "type" in kinds:
            return "DATA_ENTERED"
        if any(
            action.kind == "key_combo" and VerifierService._is_commit_key_combo(action.key_combo)
            for action in actions
        ):
            return "COMMIT_ATTEMPTED"
        if "click" in kinds or "double_click" in kinds or "select_menu_item" in kinds:
            return "UI_CONTEXT_CHANGED"
        if "open_app" in kinds:
            return "APP_ACTIVE"
        if "run_applescript" in kinds:
            return "APP_ACTIVE"
        return "APP_ACTIVE"

    @staticmethod
    def _is_commit_key_combo(combo: str | None) -> bool:
        if not combo:
            return False
        normalized = combo.lower().replace(" ", "")
        commit_tokens = {
            "enter",
            "return",
            "cmd+enter",
            "command+enter",
            "cmd+return",
            "command+return",
            "cmd+s",
            "command+s",
        }
        return normalized in commit_tokens

    @staticmethod
    def _state_rank(state: str | None) -> int | None:
        ranks = {
            "APP_ACTIVE": 0,
            "UI_CONTEXT_CHANGED": 1,
            "EDITOR_OPEN": 2,
            "FIELD_FOCUSED": 3,
            "DATA_ENTERED": 4,
            "COMMIT_ATTEMPTED": 5,
            "COMPLETED": 6,
            "BLOCKED": 6,
        }
        return ranks.get(state or "", None)

    @classmethod
    def _is_transition_sufficient(
        cls,
        *,
        expected_next_state: str | None,
        observed_state: str | None,
        previous_state: str | None,
    ) -> bool:
        if expected_next_state is None:
            return True

        if observed_state == expected_next_state:
            return True

        # Completing a form is often observed first as a commit attempt
        # before UI has reflected a final completion state.
        if expected_next_state == "COMPLETED" and observed_state == "COMMIT_ATTEMPTED":
            return True

        expected_rank = cls._state_rank(expected_next_state)
        observed_rank = cls._state_rank(observed_state)
        if expected_rank is None or observed_rank is None:
            return observed_state == expected_next_state

        if observed_rank >= expected_rank:
            return True

        _ = previous_state
        return False

    @staticmethod
    def _default_failure_reason(execution_result: str, delta_score: float) -> str:
        if execution_result == "success":
            return f"No meaningful UI/context delta detected after success report ({delta_score:.2f})"
        return "Execution did not complete successfully"

    @classmethod
    def _state_reason(
        cls,
        *,
        before_context: str,
        after_context: str,
        previous_state: str | None,
        observed_state: str | None,
        execution_result: str,
        delta_score: float,
        expected_next_state: str | None,
        first_action_kind: str | None,
    ) -> str:
        if execution_result != "success":
            return "Execution did not complete successfully"

        if expected_next_state and observed_state and observed_state != expected_next_state:
            if not cls._is_transition_sufficient(
                expected_next_state=expected_next_state,
                observed_state=observed_state,
                previous_state=previous_state,
            ):
                return (
                    f"Expected state transition to '{expected_next_state}' but observed '{observed_state}' "
                    f"(previous '{previous_state or 'UNKNOWN'}')"
                )

        if observed_state == previous_state and delta_score < 0.01:
            return f"State remained '{observed_state}' after {first_action_kind or 'action'}"

        if "app=" not in before_context and "app=" not in after_context:
            return "Context missing app information"

        return "State transition observed"
