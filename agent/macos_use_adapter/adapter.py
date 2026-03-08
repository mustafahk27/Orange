from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import json
from pathlib import Path
import re
import sys
from typing import Any

import httpx

from core.config import settings
from core.schemas import Action, LoopContext


@dataclass
class AdapterResult:
    actions: list[Action]
    confidence: float
    summary: str
    warnings: list[str]
    goal_state: str = "in_progress"
    planner_note: str | None = None
    recovery_guidance: str | None = None


@dataclass
class ProviderValidationResult:
    valid: bool
    reason: str | None = None
    account_hint: str | None = None


class ProviderConfigurationError(RuntimeError):
    def __init__(self, message: str, *, status_code: int, error_code: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.error_code = error_code


class MacOSUseAdapter:
    """
    Adapter boundary for vendored macOS-use.

    This layer reuses upstream prompt primitives (SystemPrompt) and provides a
    deterministic fallback plan when provider output is unparsable.
    """

    def __init__(self) -> None:
        self._vendor_loaded = False
        self._important_rules = ""
        self._load_vendor_prompt_rules()

    _allowed_action_kinds = {
        "click",
        "double_click",
        "type",
        "key_combo",
        "scroll",
        "open_app",
        "run_applescript",
        "select_menu_item",
        "wait",
    }

    _fallback_model_candidates = (
        "claude-3-5-sonnet-latest",
        "claude-3-5-haiku-latest",
        "claude-3-5-sonnet-20241022",
        "claude-3-5-haiku-20241022",
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307",
    )

    @property
    def provider_name(self) -> str:
        return "anthropic"

    def current_api_key(self) -> str | None:
        return settings.provider_api_key()

    async def validate_provider_key(self, api_key: str) -> ProviderValidationResult:
        key = api_key.strip()
        if not key:
            return ProviderValidationResult(valid=False, reason="API key is empty")
        if not key.startswith("sk-ant-"):
            return ProviderValidationResult(valid=False, reason="API key format is invalid")

        if not settings.enable_remote_llm:
            return ProviderValidationResult(valid=True, reason="Remote provider calls are disabled")

        url = f"{self._api_base()}/v1/models"
        headers = {
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        }
        validate_timeout = httpx.Timeout(
            timeout=settings.anthropic_validate_timeout_seconds,
            connect=min(10.0, settings.anthropic_validate_timeout_seconds),
        )
        try:
            async with httpx.AsyncClient(timeout=validate_timeout) as client:
                response = await client.get(url, headers=headers)
        except httpx.RequestError:
            return ProviderValidationResult(valid=False, reason="Network error while validating key")

        if response.status_code == 200:
            return ProviderValidationResult(
                valid=True,
                account_hint=f"Key accepted ({self._key_hint(key)})",
            )
        if response.status_code in {401, 403}:
            return ProviderValidationResult(valid=False, reason="API key is invalid or unauthorized")
        if response.status_code == 429:
            return ProviderValidationResult(
                valid=False,
                reason="API key is valid but quota/rate limit was exceeded",
                account_hint=self._key_hint(key),
            )
        if response.status_code >= 500:
            return ProviderValidationResult(valid=False, reason="Anthropic service is temporarily unavailable")

        return ProviderValidationResult(valid=False, reason=f"Provider rejected key ({response.status_code})")

    @staticmethod
    def _api_base() -> str:
        base = settings.anthropic_api_base.rstrip("/")
        if base.endswith("/v1"):
            return base[:-3]
        return base

    def _model_candidates(self, primary_model: str) -> list[str]:
        candidates = [primary_model]
        for model in self._fallback_model_candidates:
            if model not in candidates:
                candidates.append(model)
        return candidates

    @staticmethod
    def _looks_like_model_not_found(body: dict[str, Any]) -> bool:
        flattened = json.dumps(body).lower()
        return "not_found" in flattened or "not found" in flattened

    def _load_vendor_prompt_rules(self) -> None:
        vendor_path = settings.vendor_macos_use
        if not vendor_path.exists():
            return

        sys.path.insert(0, str(vendor_path))
        try:
            from mlx_use.agent.prompts import SystemPrompt  # type: ignore

            prompt = SystemPrompt(
                action_description=(
                    "open_app, click, double_click, type, key_combo, scroll, run_applescript, select_menu_item, wait"
                ),
                current_date=datetime.now(),
                max_actions_per_step=4,
            )
            self._important_rules = prompt.important_rules()
            self._vendor_loaded = True
        except Exception:
            self._important_rules = self._load_rules_from_source(vendor_path)
            self._vendor_loaded = bool(self._important_rules)
        finally:
            if str(vendor_path) in sys.path:
                sys.path.remove(str(vendor_path))

    @staticmethod
    def _load_rules_from_source(vendor_path: Path) -> str:
        prompt_file = vendor_path / "mlx_use" / "agent" / "prompts.py"
        if not prompt_file.exists():
            return ""

        content = prompt_file.read_text(encoding="utf-8")
        match = re.search(
            r"def important_rules\\(self\\) -> str:\\n\\s+\"\"\".*?\"\"\"\\n\\s+text = \"\"\"(.*?)\"\"\"",
            content,
            flags=re.DOTALL,
        )
        if not match:
            return ""
        return match.group(1).strip()

    async def plan_actions(
        self,
        *,
        transcript: str,
        active_app_name: str | None,
        _ax_tree_summary: str | None,
        loop_context: LoopContext | None,
    ) -> AdapterResult:
        if not settings.enable_remote_llm:
            return self._deterministic_plan(
                transcript=transcript,
                app_name=active_app_name,
                warnings=["Remote planner disabled"],
                loop_context=loop_context,
            )

        key = self.current_api_key()
        if not key:
            raise ProviderConfigurationError(
                "Anthropic API key not configured. Please add your key in Orange settings.",
                status_code=400,
                error_code="missing_api_key",
            )
        if not key.startswith("sk-ant-"):
            raise ProviderConfigurationError(
                "Anthropic API key format is invalid.",
                status_code=401,
                error_code="invalid_api_key_format",
            )

        return await self._plan_with_anthropic(
            transcript=transcript,
            active_app_name=active_app_name,
            ax_tree_summary=_ax_tree_summary,
            api_key=key,
            loop_context=loop_context,
        )

    async def _plan_with_anthropic(
        self,
        *,
        transcript: str,
        active_app_name: str | None,
        ax_tree_summary: str | None,
        api_key: str,
        loop_context: LoopContext | None,
    ) -> AdapterResult:
        model = self._select_model(transcript, active_app_name=active_app_name)
        prompt = self._build_provider_prompt(
            transcript=transcript,
            active_app_name=active_app_name,
            ax_tree_summary=ax_tree_summary,
            loop_context=loop_context,
        )

        payload: dict[str, Any] = {
            "temperature": 0,
            "max_tokens": 900,
            "system": "You are Orange planner. Return only valid JSON. Do not include markdown.",
            "messages": [
                {"role": "user", "content": prompt},
            ],
        }

        url = f"{self._api_base()}/v1/messages"
        headers = {
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }

        planning_timeout = httpx.Timeout(
            timeout=settings.anthropic_plan_timeout_seconds,
            connect=min(10.0, settings.anthropic_plan_timeout_seconds),
        )

        model_candidates = self._model_candidates(model)
        parse_warnings: list[str] = []

        for idx, attempt_model in enumerate(model_candidates):
            payload["model"] = attempt_model
            try:
                async with httpx.AsyncClient(timeout=planning_timeout) as client:
                    response = await client.post(url, headers=headers, json=payload)
            except httpx.RequestError as exc:
                raise ProviderConfigurationError(
                    f"Network error while contacting Anthropic: {exc.__class__.__name__}",
                    status_code=503,
                    error_code="provider_network_error",
                ) from exc

            try:
                response_body: dict[str, Any] = response.json()
            except Exception:
                response_body = {}

            if response.status_code in {401, 403}:
                raise ProviderConfigurationError(
                    "Anthropic API key is invalid or unauthorized.",
                    status_code=401,
                    error_code="invalid_api_key",
                )
            if response.status_code == 429:
                raise ProviderConfigurationError(
                    "Anthropic quota or rate limit exceeded.",
                    status_code=429,
                    error_code="provider_quota_exceeded",
                )
            if response.status_code >= 500:
                raise ProviderConfigurationError(
                    "Anthropic service is temporarily unavailable.",
                    status_code=503,
                    error_code="provider_unavailable",
                )

            if response.status_code == 404:
                if idx < len(model_candidates) - 1:
                    parse_warnings.append(f"Model {attempt_model} unavailable, trying fallback model")
                    continue
                warning_reason = (
                    "Provider returned 404 for primary model"
                    if self._looks_like_model_not_found(response_body)
                    else "Provider returned 404"
                )
                parse_warnings.append(warning_reason)
                return self._deterministic_plan(
                    transcript=transcript,
                    app_name=active_app_name,
                    warnings=[*parse_warnings],
                    loop_context=loop_context,
                )

            if response.status_code >= 300:
                raise ProviderConfigurationError(
                    f"Anthropic returned unexpected status {response.status_code}.",
                    status_code=502,
                    error_code="provider_bad_response",
                )

            body = response_body
            content_text = self._extract_text_content(body)
            if not content_text:
                return self._deterministic_plan(
                    transcript=transcript,
                    app_name=active_app_name,
                    warnings=["Provider returned empty content", *parse_warnings],
                    loop_context=loop_context,
                )

            parsed_payload = self._extract_json_payload(content_text)
            if parsed_payload is None:
                return self._deterministic_plan(
                    transcript=transcript,
                    app_name=active_app_name,
                    warnings=["Provider response was not valid JSON", *parse_warnings],
                    loop_context=loop_context,
                )

            actions, plan_warnings = self._coerce_actions(parsed_payload.get("actions", []))
            actions = self._enforce_loop_state_actions(
                actions=actions,
                loop_context=loop_context,
            )
            if not actions:
                plan_warnings = plan_warnings or ["Provider returned no valid actions"]
                warnings = list(parse_warnings)
                warnings.extend(plan_warnings)
                return AdapterResult(
                    actions=[
                        Action(
                            id="a1",
                            kind="wait",
                            timeout_ms=1000,
                            expected_outcome="Awaiting user clarification",
                        )
                    ],
                    confidence=0.2,
                    summary="Unable to parse safe actions from planner output",
                    warnings=warnings,
                    goal_state="blocked",
                    planner_note="Planner output could not be parsed safely.",
                    recovery_guidance="Try a shorter command or mention the app and target explicitly.",
                )

            confidence = self._clamp_confidence(parsed_payload.get("confidence"))
            summary = str(parsed_payload.get("summary") or "Anthropic generated plan")
            goal_state = self._coerce_goal_state(parsed_payload, actions=actions, loop_context=loop_context)
            planner_note = cast_optional_str(parsed_payload.get("planner_note"))
            if attempt_model != model:
                fallback_note = f"[fallback model: {attempt_model}]"
                planner_note = (
                    f"{fallback_note} {planner_note}" if planner_note else fallback_note
                ).strip()
            return AdapterResult(
                actions=actions,
                confidence=confidence,
                summary=summary,
                warnings=parse_warnings + plan_warnings,
                goal_state=goal_state,
                planner_note=planner_note,
            )

        return self._deterministic_plan(
            transcript=transcript,
            app_name=active_app_name,
            warnings=["Provider model retries exhausted"],
            loop_context=loop_context,
        )

    def _extract_text_content(self, payload: dict[str, Any]) -> str | None:
        content = payload.get("content")
        if not isinstance(content, list):
            return None
        parts: list[str] = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
                parts.append(block["text"])
        joined = "\n".join(parts).strip()
        return joined or None

    def _extract_json_payload(self, text: str) -> dict[str, Any] | None:
        stripped = text.strip()
        try:
            parsed = json.loads(stripped)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass

        match = re.search(r"\{[\s\S]*\}", stripped)
        if not match:
            return None
        try:
            parsed = json.loads(match.group(0))
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            return None
        return None

    def _coerce_actions(self, raw_actions: list[dict[str, Any]]) -> tuple[list[Action], list[str]]:
        actions: list[Action] = []
        warnings: list[str] = []
        for idx, raw in enumerate(raw_actions, start=1):
            if not isinstance(raw, dict):
                warnings.append(f"Action #{idx} is not an object")
                continue
            kind = str(raw.get("kind") or "").strip()
            if kind not in self._allowed_action_kinds:
                warnings.append(f"Rejected unknown action kind '{kind or 'missing'}' at index {idx}")
                continue
            try:
                target = cast_optional_str(raw.get("target"))
                text = cast_optional_str(raw.get("text"))
                key_combo = cast_optional_str(raw.get("key_combo"))
                app_bundle_id = cast_optional_str(raw.get("app_bundle_id"))
                invalid_fields = self._missing_required_fields(
                    kind=kind,
                    target=target,
                    text=text,
                    key_combo=key_combo,
                    app_bundle_id=app_bundle_id,
                )
                if invalid_fields:
                    warnings.append(
                        f"Rejected invalid action at index {idx}: missing required field(s) {', '.join(invalid_fields)} for kind '{kind}'"
                    )
                    continue
                if kind in {"click", "double_click", "select_menu_item", "scroll"} and self._looks_like_placeholder_target(
                    target
                ):
                    warnings.append(
                        f"Rejected invalid action at index {idx}: placeholder target '{target}' for kind '{kind}'"
                    )
                    continue
                actions.append(
                    Action(
                        id=str(raw.get("id") or f"a{idx}"),
                        kind=kind,  # type: ignore[arg-type]
                        target=target,
                        text=text,
                        key_combo=key_combo,
                        app_bundle_id=app_bundle_id,
                        timeout_ms=cast_int(raw.get("timeout_ms"), default=3000),
                        destructive=bool(raw.get("destructive", False)),
                        expected_outcome=cast_optional_str(raw.get("expected_outcome")),
                    )
                )
            except Exception as exc:
                warnings.append(f"Rejected invalid action at index {idx}: {exc}")
                continue
        return actions, warnings

    @staticmethod
    def _looks_like_placeholder_target(target: str | None) -> bool:
        if not target:
            return True
        normalized = re.sub(r"\s+", " ", target.strip().lower())
        explicit_placeholders = {
            "first_search_result",
            "search_result",
            "first result",
            "top result",
            "search bar",
            "search field",
            "current field",
            "focused field",
            "input field",
        }
        if normalized in explicit_placeholders:
            return True
        if normalized.startswith("first_") and normalized.endswith("_result"):
            return True
        return False

    @staticmethod
    def _missing_required_fields(
        *,
        kind: str,
        target: str | None,
        text: str | None,
        key_combo: str | None,
        app_bundle_id: str | None,
    ) -> list[str]:
        missing: list[str] = []
        if kind in {"click", "double_click", "select_menu_item", "scroll"} and not target:
            missing.append("target")
        if kind == "open_app" and not target and not app_bundle_id:
            missing.append("target|app_bundle_id")
        if kind in {"type", "run_applescript"} and not text:
            missing.append("text")
        if kind == "key_combo" and not key_combo:
            missing.append("key_combo")
        return missing

    def _enforce_loop_state_actions(
        self,
        *,
        actions: list[Action],
        loop_context: LoopContext | None,
    ) -> list[Action]:
        if not loop_context:
            return actions

        expected_state = loop_context.next_required_state
        if expected_state not in {"COMMIT_ATTEMPTED", "COMPLETED"}:
            return actions

        filtered: list[Action] = []
        for action in actions:
            if action.kind == "open_app":
                continue
            if action.kind == "type":
                continue
            if action.kind == "key_combo":
                combo = (action.key_combo or "").strip().lower().replace(" ", "")
                if combo in {"cmd+n", "command+n", "tab"}:
                    continue
            filtered.append(action)

        if expected_state == "COMPLETED":
            # Completion phase should not reopen/retype; only confirm/commit.
            filtered = [action for action in filtered if self._is_commit_action(action) or action.kind == "wait"]

        if not any(self._is_commit_action(action) for action in filtered):
            filtered.insert(
                0,
                Action(
                    id="a1",
                    kind="key_combo",
                    key_combo="return",
                    timeout_ms=900,
                    expected_outcome="Commit current form",
                ),
            )

        return self._reindex_actions(filtered[:3])

    @staticmethod
    def _is_commit_action(action: Action) -> bool:
        if action.kind == "key_combo":
            combo = (action.key_combo or "").strip().lower().replace(" ", "")
            return combo in {
                "enter",
                "return",
                "cmd+enter",
                "command+enter",
                "cmd+return",
                "command+return",
                "cmd+s",
                "command+s",
            }
        if action.kind == "select_menu_item":
            target = (action.target or "").strip().lower()
            return any(token in target for token in ("save", "done", "ok", "confirm"))
        return False

    @staticmethod
    def _reindex_actions(actions: list[Action]) -> list[Action]:
        return [action.model_copy(update={"id": f"a{idx}"}) for idx, action in enumerate(actions, start=1)]

    def _build_provider_prompt(
        self,
        *,
        transcript: str,
        active_app_name: str | None,
        ax_tree_summary: str | None,
        loop_context: LoopContext | None,
    ) -> str:
        app_name = active_app_name or "Unknown"
        ax_preview = (ax_tree_summary or "")[:3500]
        app_pack = self._app_prompt_pack(app_name)
        vendor_rules = self._important_rules[:2400] if self._important_rules else ""
        loop_text = "none"
        if loop_context:
            recent_outcomes = self._format_recent_outcomes(loop_context.recent_action_results)
            loop_text = (
                f"goal={loop_context.goal_transcript}; "
                f"cycle_index={loop_context.cycle_index}; "
                f"replan_count={loop_context.replan_count}; "
                f"max_cycles={loop_context.max_cycles}; "
                f"max_replans={loop_context.max_replans}; "
                f"current_state={loop_context.current_state}; "
                f"next_required_state={loop_context.next_required_state}; "
                f"last_state={loop_context.last_state}; "
                f"last_verify_status={loop_context.last_verify_status}; "
                f"last_verify_reason={loop_context.last_verify_reason}; "
                f"recent_action_results={recent_outcomes}"
            )
        return (
            "Plan safe macOS actions for this user request.\n"
            "This is a stepwise autonomous loop. Plan only the NEXT micro-step (1-3 actions), not the whole task.\n"
            "Return strictly JSON with shape: "
            '{"summary":"...", "confidence":0.0-1.0, "goal_state":"in_progress|complete|blocked", "planner_note":"...", "actions":[{"id":"a1","kind":"open_app|click|double_click|type|key_combo|scroll|run_applescript|select_menu_item|wait","target":null,"text":null,"key_combo":null,"app_bundle_id":null,"timeout_ms":3000,"destructive":false,"expected_outcome":null}]}\n'
            "Use the fewest actions needed.\n"
            "If previous cycle failed, do not repeat the same failed action target/text combo.\n"
            "If loop_context.current_state and loop_context.next_required_state are present, plan explicitly toward that transition target.\n"
            "Field discipline policy (applies to any form UI):\n"
            "- A type action must target the currently focused field only. If focus is uncertain, add a focus action first (tab/click/key_combo) before typing.\n"
            "- Never type the full user transcript/command sentence into a field. Extract only task data values.\n"
            "- Click-like actions (click/double_click/select_menu_item/scroll) must have a non-empty target. If target is unknown, do not emit click; use key_combo focus navigation or wait.\n"
            "- Never use placeholder targets such as first_search_result/search_bar/current_field. Use an actual AX label/index from AX summary.\n"
            "- Treat title/date/time/location/body as separate slots. Never place time/date text into a title/name field.\n"
            "- Do not emit two type actions for different slots back-to-back unless there is an explicit focus-change action between them.\n"
            "- If micro-step budget (1-3 actions) is tight, fill one slot and end with a navigation/commit action; continue next slot in the next cycle.\n"
            "State transition policy:\n"
            "- current_state=APP_ACTIVE: ensure the correct app/context is active or opened only once.\n"
            "- current_state=UI_CONTEXT_CHANGED: move focus to the intended control (tab/arrow/click), avoid retyping the whole task.\n"
            "- current_state=DATA_ENTERED: do not emit another type action for title/time/body again. Prefer progress actions (tab, return, key_combo save/commit, menu item save/Done).\n"
            "- current_state=COMMIT_ATTEMPTED: verify completion and, if needed, open/locate a clear save/confirm result.\n"
            "- If next_required_state=COMMIT_ATTEMPTED, do not use create-new-item shortcuts (for example cmd+n); perform commit/save/confirm actions only.\n"
            "- If data was already typed in a form-like workflow, next cycle should finalize/commit, then verify completion.\n"
            "If a click failed, try an alternative strategy (menu item, key combo, focus step, or wait).\n"
            "If a previous cycle replan was needed, and this cycle still reports no progress, change strategy immediately (shortcut-first/menu path) and do not retry identical action signatures.\n"
            "For form tasks, prefer stable key_combo shortcuts and focus navigation before brittle click paths.\n"
            "Prefer actionable controls (buttons, menu items, text fields) and avoid static text labels.\n"
            "Do not call open_app for the currently active app unless the command requires switching to a different app.\n"
            "If last_verify_status is success, continue with the next workflow step instead of reopening the same app.\n"
            "When context already shows the target app, avoid emitting open_app on that same app in consecutive cycles.\n"
            "If task is complete from current context, return goal_state=complete and actions=[].\n"
            "If blocked and cannot proceed safely, return goal_state=blocked with planner_note.\n"
            f"Active app: {app_name}\n"
            f"User transcript: {transcript}\n"
            f"Loop context: {loop_text}\n"
            f"AX summary: {ax_preview}\n"
            f"App-specific guidance: {app_pack}\n"
            f"Safety rules excerpt: {vendor_rules}\n"
        )

    @staticmethod
    def _format_recent_outcomes(outcomes: list) -> str:
        if not outcomes:
            return "none"
        rendered: list[str] = []
        for outcome in outcomes[-6:]:
            hint = (outcome.action_hint or "").strip() if hasattr(outcome, "action_hint") else ""
            if len(hint) > 120:
                hint = hint[:120]
            rendered.append(
                f"{outcome.kind}:{outcome.status}:error={outcome.error_code or 'none'}:hint={hint or 'n/a'}"
            )
        return " | ".join(rendered)

    def _select_model(self, transcript: str, *, active_app_name: str | None) -> str:
        if active_app_name:
            override = settings.model_overrides.get(active_app_name.lower())
            if override:
                return override
        complexity_markers = [" and ", " then ", "after", "before", "reply", "send", "purchase"]
        lower = transcript.lower()
        is_complex = len(lower.split()) > 10 or any(marker in lower for marker in complexity_markers)
        return settings.model_complex if is_complex else settings.model_simple

    def _app_prompt_pack(self, app_name: str) -> str:
        key = app_name.lower()
        packs = {
            "mail": "Prefer semantic compose/reply flows; require confirmation before send.",
            "gmail": "Focus reply box detection and avoid pressing send without explicit user confirmation.",
            "slack": "Prioritize active thread composer; avoid posting to wrong channel.",
            "safari": "Use cmd+l for address bar and confirm page load target.",
            "google chrome": "Use cmd+l for omnibox and verify URL matches intent.",
            "finder": "Prefer menu actions for create/rename/move and avoid destructive operations by default.",
        }
        return packs.get(key, "Use safest deterministic actions and avoid irreversible operations.")

    @staticmethod
    def _clamp_confidence(value: Any) -> float:
        try:
            confidence = float(value)
        except Exception:
            confidence = 0.7
        return max(0.0, min(1.0, confidence))

    def _deterministic_plan(
        self,
        *,
        transcript: str,
        app_name: str | None,
        warnings: list[str],
        loop_context: LoopContext | None,
    ) -> AdapterResult:
        text = transcript.strip().lower()
        app_name = (app_name or "").strip()
        if loop_context and loop_context.cycle_index >= loop_context.max_cycles:
            return AdapterResult(
                actions=[],
                confidence=0.6,
                summary="Loop budget reached",
                warnings=warnings,
                goal_state="blocked",
                planner_note="No further planning due to cycle budget limits.",
                recovery_guidance="Ask user for clarification or a narrower request.",
            )

        if text.startswith("open "):
            target = transcript.strip()[5:].strip()
            return AdapterResult(
                actions=[
                    Action(
                        id="a1",
                        kind="open_app",
                        target=target,
                        expected_outcome=f"{target} is frontmost",
                    )
                ],
                confidence=0.82,
                summary=f"Open {target}",
                warnings=warnings,
                goal_state="in_progress",
                recovery_guidance="Fell back to deterministic planner due to provider output issues.",
            )

        url_match = re.search(r"(https?://\S+|\b\w+\.com\b)", text)
        if "go to" in text and url_match:
            raw_url = url_match.group(1)
            url = raw_url if raw_url.startswith("http") else f"https://{raw_url}"
            browser_target = app_name if app_name in {"Safari", "Google Chrome"} else "Safari"
            return AdapterResult(
                actions=[
                    Action(id="a1", kind="open_app", target=browser_target, expected_outcome="Browser opened"),
                    Action(id="a2", kind="key_combo", key_combo="cmd+l", expected_outcome="Address bar focused"),
                    Action(id="a3", kind="type", text=url, expected_outcome=f"URL entered: {url}"),
                    Action(id="a4", kind="key_combo", key_combo="enter", expected_outcome="Page loads"),
                ],
                confidence=0.75,
                summary=f"Navigate to {url}",
                warnings=warnings,
                goal_state="in_progress",
                recovery_guidance="Fell back to deterministic planner due to provider output issues.",
            )

        return AdapterResult(
            actions=[
                Action(
                    id="a1",
                    kind="type",
                    text=transcript,
                    expected_outcome="Transcript typed in focused input",
                )
            ],
            confidence=0.55,
            summary="Type transcript in focused field",
            warnings=warnings,
            goal_state="in_progress",
            recovery_guidance="Fell back to deterministic planner due to provider output issues.",
        )

    @staticmethod
    def _coerce_goal_state(
        payload: dict[str, Any],
        *,
        actions: list[Action],
        loop_context: LoopContext | None,
    ) -> str:
        raw = str(payload.get("goal_state") or "").strip().lower()
        if raw in {"in_progress", "complete", "blocked"}:
            return raw

        if isinstance(payload.get("done"), bool) and payload.get("done") is True:
            return "complete"

        if (
            loop_context
            and loop_context.current_state == "COMMIT_ATTEMPTED"
            and loop_context.next_required_state == "COMPLETED"
            and loop_context.last_verify_status == "success"
        ):
            return "complete"

        if not actions:
            if loop_context and loop_context.cycle_index >= loop_context.max_cycles:
                return "blocked"
            return "complete"
        return "in_progress"

    @staticmethod
    def _key_hint(key: str) -> str:
        tail = key[-4:] if len(key) >= 4 else "****"
        return f"••••{tail}"

    @property
    def vendor_loaded(self) -> bool:
        return self._vendor_loaded

    @property
    def vendor_rules(self) -> str:
        return self._important_rules



def cast_optional_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None



def cast_int(value: Any, *, default: int) -> int:
    try:
        return int(value)
    except Exception:
        return default
