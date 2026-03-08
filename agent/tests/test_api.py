from __future__ import annotations

import os

from fastapi.testclient import TestClient

from app import main as app_main
from app.main import app
from core.schemas import Action, LoopContext
from macos_use_adapter.adapter import AdapterResult
from macos_use_adapter.adapter import MacOSUseAdapter


client = TestClient(app)


def test_health() -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_plan_requires_api_key(monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    payload = {
        "schema_version": 1,
        "session_id": "session-missing-key",
        "transcript": "open Safari",
        "app": {"name": "Finder", "bundle_id": "com.apple.finder"},
    }
    response = client.post("/v1/plan", json=payload)
    assert response.status_code == 400
    body = response.json()
    assert body["detail"]["error_code"] == "missing_api_key"


def test_plan_invalid_key_format(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-a-valid-key")
    payload = {
        "schema_version": 1,
        "session_id": "session-invalid-key",
        "transcript": "open Safari",
        "app": {"name": "Finder", "bundle_id": "com.apple.finder"},
    }
    response = client.post("/v1/plan", json=payload)
    assert response.status_code == 401
    body = response.json()
    assert body["detail"]["error_code"] == "invalid_api_key_format"


def test_plan_returns_actions_with_valid_key(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test-plan-key")

    async def fake_plan_with_anthropic(
        *,
        transcript: str,
        active_app_name: str | None,
        ax_tree_summary: str | None,
        api_key: str,
        loop_context,
    ) -> AdapterResult:  # noqa: ARG001
        return AdapterResult(
            actions=[Action(id="a1", kind="open_app", target="Safari", expected_outcome="Safari opened")],
            confidence=0.9,
            summary="Open Safari",
            warnings=[],
        )

    monkeypatch.setattr(app_main._planner._adapter, "_plan_with_anthropic", fake_plan_with_anthropic)

    payload = {
        "schema_version": 1,
        "session_id": "session-valid-key",
        "transcript": "open Safari",
        "app": {"name": "Finder", "bundle_id": "com.apple.finder"},
    }
    response = client.post("/v1/plan", json=payload)
    assert response.status_code == 200

    body = response.json()
    assert body["session_id"] == "session-valid-key"
    assert body["actions"]
    assert body["actions"][0]["kind"] == "open_app"
    assert body["goal_state"] == "in_progress"


def test_provider_status_and_validate_endpoints(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-status-key")

    status_response = client.get("/v1/provider/status")
    assert status_response.status_code == 200
    status_body = status_response.json()
    assert status_body["provider"] == "anthropic"
    assert status_body["key_configured"] is True
    assert "model_simple" in status_body
    assert "model_complex" in status_body
    assert status_body["health"] is True

    # Invalid format should fail before network call.
    validate_response = client.post(
        "/v1/provider/validate",
        json={"provider": "anthropic", "api_key": "invalid-key-format"},
    )
    assert validate_response.status_code == 200
    validate_body = validate_response.json()
    assert validate_body["provider"] == "anthropic"
    assert validate_body["valid"] is False


def test_verify_failure_returns_corrective_action() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify",
        "actions": [
            {
                "id": "a1",
                "kind": "click",
                "target": "Send button",
                "timeout_ms": 3000,
                "destructive": False,
            }
        ],
        "confidence": 0.8,
        "risk_level": "medium",
        "requires_confirmation": True,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify",
        "action_plan": plan,
        "execution_result": "failure",
        "reason": "Element not found",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failure"
    assert len(body["corrective_actions"]) == 1


def test_verify_failure_retries_from_failed_action_forward() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-suffix",
        "actions": [
            {"id": "a1", "kind": "click", "target": "Date cell", "timeout_ms": 3000, "destructive": False},
            {"id": "a2", "kind": "type", "text": "iftar Drive", "timeout_ms": 3000, "destructive": False},
            {"id": "a3", "kind": "key_combo", "key_combo": "enter", "timeout_ms": 3000, "destructive": False},
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-suffix",
        "action_plan": plan,
        "execution_result": "failure",
        "failed_action_id": "a2",
        "completed_actions": ["a1"],
        "reason": "Typing failed",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failure"
    assert [item["kind"] for item in body["corrective_actions"]] == ["type", "key_combo"]


def test_verify_success_without_delta_replans_without_corrective() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-success-no-delta",
        "actions": [
            {"id": "a1", "kind": "click", "target": "Date cell", "timeout_ms": 3000, "destructive": False}
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-success-no-delta",
        "action_plan": plan,
        "execution_result": "success",
        "before_context": "same",
        "after_context": "same",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "failure"
    assert body["corrective_actions"] == []


def test_plan_simulate_requires_api_key(monkeypatch) -> None:
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    payload = {
        "schema_version": 1,
        "session_id": "session-sim-no-key",
        "transcript": "open Safari and go to openai.com",
        "app": {"name": "Finder"},
    }
    response = client.post("/v1/plan/simulate", json=payload)
    assert response.status_code == 400


def test_models_endpoint() -> None:
    response = client.get("/v1/models")
    assert response.status_code == 200
    body = response.json()
    assert body["schema_version"] == 1
    assert isinstance(body["routing"], list)
    assert isinstance(body["feature_flags"], dict)


def test_telemetry_round_trip() -> None:
    event = {
        "session_id": "session-t1",
        "stage": "executing",
        "status": "success",
        "latency_ms": 123,
    }
    post_response = client.post("/v1/telemetry", json=event)
    assert post_response.status_code == 200
    assert post_response.json()["status"] == "accepted"

    get_response = client.get("/v1/telemetry?limit=1")
    assert get_response.status_code == 200
    body = get_response.json()
    assert len(body["events"]) == 1
    assert body["events"][0]["session_id"] == "session-t1"


def test_plan_accepts_loop_context_and_complete_goal_state(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test-plan-key")

    async def fake_plan_with_anthropic(
        *,
        transcript: str,
        active_app_name: str | None,
        ax_tree_summary: str | None,
        api_key: str,
        loop_context,
    ) -> AdapterResult:  # noqa: ARG001
        assert loop_context is not None
        return AdapterResult(
            actions=[],
            confidence=0.91,
            summary="Goal complete",
            warnings=[],
            goal_state="complete",
            planner_note="No further actions needed.",
        )

    monkeypatch.setattr(app_main._planner._adapter, "_plan_with_anthropic", fake_plan_with_anthropic)

    payload = {
        "schema_version": 1,
        "session_id": "session-loop-complete",
        "transcript": "create a reminder",
        "app": {"name": "Notes"},
        "loop_context": {
            "goal_transcript": "create a reminder for tomorrow 5 pm",
            "cycle_index": 2,
            "replan_count": 1,
            "max_cycles": 6,
            "max_replans": 2,
            "last_verify_status": "success",
            "last_verify_reason": None,
            "recent_action_results": [],
        },
    }
    response = client.post("/v1/plan", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["goal_state"] == "complete"
    assert body["planner_note"] == "No further actions needed."
    assert body["actions"] == []


def test_plan_trims_loop_actions_to_micro_batch(monkeypatch) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test-plan-key")

    async def fake_plan_with_anthropic(
        *,
        transcript: str,
        active_app_name: str | None,
        ax_tree_summary: str | None,
        api_key: str,
        loop_context,
    ) -> AdapterResult:  # noqa: ARG001
        return AdapterResult(
            actions=[
                Action(id="a1", kind="click", target="one"),
                Action(id="a2", kind="click", target="two"),
                Action(id="a3", kind="click", target="three"),
                Action(id="a4", kind="click", target="four"),
            ],
            confidence=0.8,
            summary="Too many actions",
            warnings=[],
        )

    monkeypatch.setattr(app_main._planner._adapter, "_plan_with_anthropic", fake_plan_with_anthropic)

    payload = {
        "schema_version": 1,
        "session_id": "session-micro-batch",
        "transcript": "do next step",
        "app": {"name": "Notes"},
        "loop_context": {
            "goal_transcript": "goal",
            "cycle_index": 1,
            "replan_count": 0,
            "max_cycles": 6,
            "max_replans": 2,
            "last_verify_status": "failure",
            "last_verify_reason": "not found",
            "recent_action_results": [],
        },
    }
    response = client.post("/v1/plan", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert len(body["actions"]) == 3


def test_coerce_actions_rejects_click_without_target() -> None:
    adapter = MacOSUseAdapter()
    actions, warnings = adapter._coerce_actions(
        [
            {"id": "a1", "kind": "click", "target": "   "},
            {"id": "a2", "kind": "type", "text": "Avtar Drive"},
        ]
    )

    assert len(actions) == 1
    assert actions[0].kind == "type"
    assert any("missing required field(s) target for kind 'click'" in warning for warning in warnings)


def test_commit_required_state_filters_create_actions_and_forces_commit() -> None:
    adapter = MacOSUseAdapter()
    loop_context = LoopContext(
        goal_transcript="complete form submission",
        cycle_index=2,
        replan_count=1,
        max_cycles=10,
        max_replans=4,
        current_state="DATA_ENTERED",
        next_required_state="COMMIT_ATTEMPTED",
        last_state="FIELD_FOCUSED",
        last_verify_status="failure",
        last_verify_reason="Expected COMMIT_ATTEMPTED",
        recent_action_results=[],
    )
    actions = [
        Action(id="a1", kind="key_combo", key_combo="cmd+n"),
        Action(id="a2", kind="type", text="Event at 5 pm"),
        Action(id="a3", kind="key_combo", key_combo="tab"),
    ]

    guarded = adapter._enforce_loop_state_actions(actions=actions, loop_context=loop_context)

    assert guarded
    assert all(action.kind != "type" for action in guarded)
    assert all((action.key_combo or "").lower().replace(" ", "") != "cmd+n" for action in guarded if action.kind == "key_combo")
    assert any((action.key_combo or "").lower().replace(" ", "") in {"return", "enter", "cmd+s", "command+s"} for action in guarded if action.kind == "key_combo")


def test_completed_required_state_filters_to_commit_only() -> None:
    adapter = MacOSUseAdapter()
    loop_context = LoopContext(
        goal_transcript="complete form submission",
        cycle_index=3,
        replan_count=1,
        max_cycles=10,
        max_replans=4,
        current_state="COMMIT_ATTEMPTED",
        next_required_state="COMPLETED",
        last_state="DATA_ENTERED",
        last_verify_status="success",
        last_verify_reason="commit attempted",
        recent_action_results=[],
    )
    actions = [
        Action(id="a1", kind="key_combo", key_combo="cmd+n"),
        Action(id="a2", kind="type", text="Film event"),
        Action(id="a3", kind="key_combo", key_combo="tab"),
    ]

    guarded = adapter._enforce_loop_state_actions(actions=actions, loop_context=loop_context)

    assert guarded
    assert all(action.kind != "type" for action in guarded)
    assert all((action.key_combo or "").lower().replace(" ", "") != "cmd+n" for action in guarded if action.kind == "key_combo")
    assert any((action.key_combo or "").lower().replace(" ", "") in {"return", "enter", "cmd+s", "command+s"} for action in guarded if action.kind == "key_combo")


def test_verify_cmd_s_counts_as_commit_attempt() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-commit-save",
        "actions": [
            {
                "id": "a1",
                "kind": "key_combo",
                "key_combo": "cmd+s",
                "timeout_ms": 3000,
                "destructive": False,
            }
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-commit-save",
        "action_plan": plan,
        "execution_result": "success",
        "loop_context": {
            "goal_transcript": "save event",
            "cycle_index": 2,
            "replan_count": 1,
            "max_cycles": 10,
            "max_replans": 4,
            "current_state": "DATA_ENTERED",
            "next_required_state": "COMMIT_ATTEMPTED",
            "last_state": "FIELD_FOCUSED",
            "last_verify_status": "failure",
            "last_verify_reason": "needs commit",
            "recent_action_results": [],
        },
        "before_context": "app=Notes, window=New Note, url=n/a, ax_lines=20",
        "after_context": "app=Notes, window=New Note, url=n/a, ax_lines=20",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert body["state"] == "COMMIT_ATTEMPTED"


def test_verify_completed_accepts_commit_attempted_progress() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-completed-via-commit",
        "actions": [
            {
                "id": "a1",
                "kind": "key_combo",
                "key_combo": "return",
                "timeout_ms": 3000,
                "destructive": False,
            }
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-completed-via-commit",
        "action_plan": plan,
        "execution_result": "success",
        "loop_context": {
            "goal_transcript": "save event",
            "cycle_index": 3,
            "replan_count": 1,
            "max_cycles": 10,
            "max_replans": 4,
            "current_state": "COMMIT_ATTEMPTED",
            "next_required_state": "COMPLETED",
            "last_state": "DATA_ENTERED",
            "last_verify_status": "success",
            "last_verify_reason": "commit attempted",
            "recent_action_results": [],
        },
        "before_context": "app=Notes, window=New Note, url=n/a, ax_lines=20",
        "after_context": "app=Notes, window=New Note, url=n/a, ax_lines=20",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert body["state"] == "COMMIT_ATTEMPTED"


def test_verify_success_with_expected_state_progression() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-state",
        "actions": [
            {
                "id": "a1",
                "kind": "key_combo",
                "key_combo": "cmd+l",
                "timeout_ms": 3000,
                "destructive": False,
            },
            {
                "id": "a2",
                "kind": "type",
                "text": "apple.com",
                "timeout_ms": 3000,
                "destructive": False,
            },
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-state",
        "action_plan": plan,
        "execution_result": "success",
        "loop_context": {
            "goal_transcript": "open url",
            "cycle_index": 0,
            "replan_count": 0,
            "max_cycles": 6,
            "max_replans": 2,
            "current_state": "APP_ACTIVE",
            "next_required_state": "UI_CONTEXT_CHANGED",
            "last_state": None,
            "last_verify_status": "failure",
            "last_verify_reason": "none",
            "recent_action_results": [],
        },
        "before_context": "app=Safari, window=Window 1, url=about:blank, ax_lines=2",
        "after_context": "app=Safari, window=Address Bar, url=https://apple.com, ax_lines=2",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()

    assert body["status"] == "success"
    assert body["state"] == "UI_CONTEXT_CHANGED"
    assert body["required_transition"] == "DATA_ENTERED"


def test_verify_no_progress_for_redundant_open_app() -> None:
    plan = {
        "schema_version": 1,
        "session_id": "session-verify-noop",
        "actions": [
            {
                "id": "a1",
                "kind": "open_app",
                "target": "Notes",
                "timeout_ms": 3000,
                "destructive": False,
            }
        ],
        "confidence": 0.8,
        "risk_level": "low",
        "requires_confirmation": False,
    }
    payload = {
        "schema_version": 1,
        "session_id": "session-verify-noop",
        "action_plan": plan,
        "execution_result": "success",
        "loop_context": {
            "goal_transcript": "open notes",
            "cycle_index": 1,
            "replan_count": 0,
            "max_cycles": 6,
            "max_replans": 2,
            "current_state": "UI_CONTEXT_CHANGED",
            "next_required_state": "FIELD_FOCUSED",
            "last_state": "APP_ACTIVE",
            "last_verify_status": "success",
            "last_verify_reason": "previously opened",
            "recent_action_results": [],
        },
        "before_context": "app=Notes, window=All iCloud, url=n/a, ax_lines=7",
        "after_context": "app=Notes, window=All iCloud, url=n/a, ax_lines=7",
    }

    response = client.post("/v1/verify", json=payload)
    assert response.status_code == 200
    body = response.json()

    assert body["status"] == "failure"
    assert body["state"] == "APP_ACTIVE"
    assert "Open-app action did not change active app or window" in body["reason"]
