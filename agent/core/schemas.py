from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .config import SCHEMA_VERSION_CURRENT, SCHEMA_VERSION_MIN


ActionKind = Literal[
    "click",
    "double_click",
    "type",
    "key_combo",
    "scroll",
    "open_app",
    "run_applescript",
    "select_menu_item",
    "wait",
]
RiskLevel = Literal["low", "medium", "high"]
GoalState = Literal["in_progress", "complete", "blocked"]
ExecutionStatus = Literal["success", "failure", "partial"]
LoopState = Literal[
    "APP_ACTIVE",
    "UI_CONTEXT_CHANGED",
    "EDITOR_OPEN",
    "FIELD_FOCUSED",
    "DATA_ENTERED",
    "COMMIT_ATTEMPTED",
    "COMPLETED",
    "BLOCKED",
]
EventSeverity = Literal["info", "warning", "error"]
ProviderName = Literal["anthropic"]


class AppMetadata(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str | None = None
    bundle_id: str | None = None
    window_title: str | None = None
    url: str | None = None


class PlannerPreferences(BaseModel):
    model_config = ConfigDict(extra="forbid")

    preferred_model: str | None = None
    locale: str | None = None
    low_latency: bool = True


class LoopActionOutcome(BaseModel):
    model_config = ConfigDict(extra="forbid")

    action_id: str
    kind: str
    status: str
    error_code: str | None = None
    action_hint: str | None = None


class LoopContext(BaseModel):
    model_config = ConfigDict(extra="forbid")

    goal_transcript: str = Field(min_length=1, max_length=4000)
    cycle_index: int = Field(ge=0, le=100)
    replan_count: int = Field(ge=0, le=100)
    max_cycles: int = Field(ge=1, le=100)
    max_replans: int = Field(ge=0, le=100)
    current_state: LoopState | None = None
    next_required_state: LoopState | None = None
    last_state: LoopState | None = None
    last_verify_status: str | None = None
    last_verify_reason: str | None = None
    recent_action_results: list[LoopActionOutcome] = Field(default_factory=list)


class Action(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1)
    kind: ActionKind
    target: str | None = None
    text: str | None = None
    key_combo: str | None = None
    app_bundle_id: str | None = None
    timeout_ms: int = Field(default=3000, ge=100, le=120000)
    destructive: bool = False
    expected_outcome: str | None = None


class ActionPlan(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str = Field(min_length=1)
    actions: list[Action] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)
    risk_level: RiskLevel
    requires_confirmation: bool
    summary: str | None = None
    goal_state: GoalState = "in_progress"
    planner_note: str | None = None


class PlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str = Field(min_length=1)
    transcript: str = Field(min_length=1, max_length=4000)
    screenshot_base64: str | None = None
    ax_tree_summary: str | None = None
    loop_context: LoopContext | None = None
    app: AppMetadata | None = None
    preferences: PlannerPreferences | None = None

    @field_validator("schema_version")
    @classmethod
    def schema_version_supported(cls, value: int) -> int:
        if value < SCHEMA_VERSION_MIN or value > SCHEMA_VERSION_CURRENT:
            raise ValueError(
                f"Unsupported schema_version={value}; supported=[{SCHEMA_VERSION_MIN}, {SCHEMA_VERSION_CURRENT}]"
            )
        return value


class PlanSimulationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str = Field(min_length=1)
    transcript: str = Field(min_length=1, max_length=4000)
    app: AppMetadata | None = None
    preferences: PlannerPreferences | None = None

    @field_validator("schema_version")
    @classmethod
    def schema_version_supported(cls, value: int) -> int:
        if value < SCHEMA_VERSION_MIN or value > SCHEMA_VERSION_CURRENT:
            raise ValueError(
                f"Unsupported schema_version={value}; supported=[{SCHEMA_VERSION_MIN}, {SCHEMA_VERSION_CURRENT}]"
            )
        return value


class PlanSimulationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str
    is_valid: bool
    parse_errors: list[str] = Field(default_factory=list)
    risk_level: RiskLevel
    requires_confirmation: bool
    summary: str
    proposed_actions_count: int = 0
    recovery_guidance: str | None = None


class VerifyRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str = Field(min_length=1)
    action_plan: ActionPlan
    execution_result: ExecutionStatus
    failed_action_id: str | None = None
    completed_actions: list[str] = Field(default_factory=list)
    reason: str | None = None
    before_context: str | None = None
    after_context: str | None = None
    loop_context: LoopContext | None = None

    @field_validator("schema_version")
    @classmethod
    def schema_version_supported(cls, value: int) -> int:
        if value < SCHEMA_VERSION_MIN or value > SCHEMA_VERSION_CURRENT:
            raise ValueError(
                f"Unsupported schema_version={value}; supported=[{SCHEMA_VERSION_MIN}, {SCHEMA_VERSION_CURRENT}]"
            )
        return value


class VerifyResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    session_id: str
    status: Literal["success", "failure"]
    confidence: float = Field(ge=0.0, le=1.0)
    reason: str | None = None
    state: LoopState | None = None
    required_transition: LoopState | None = None
    state_reason: str | None = None
    corrective_actions: list[Action] = Field(default_factory=list)


class StreamEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    session_id: str
    event: str
    message: str
    progress: int | None = Field(default=None, ge=0, le=100)
    step_id: str | None = None
    severity: EventSeverity = "info"
    timestamp: str = Field(default_factory=lambda: datetime.now(timezone.utc).isoformat())


class ModelInfo(BaseModel):
    model_config = ConfigDict(extra="forbid")

    app: str | None = None
    model: str
    reason: str


class ModelsResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: int = SCHEMA_VERSION_CURRENT
    routing: list[ModelInfo]
    feature_flags: dict[str, str]


class TelemetryEvent(BaseModel):
    model_config = ConfigDict(extra="forbid")

    session_id: str = Field(min_length=1)
    timestamp: str = Field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    stage: str
    app: str | None = None
    action_kind: str | None = None
    status: str
    latency_ms: int | None = Field(default=None, ge=0)
    error_code: str | None = None
    cycle_index: int | None = Field(default=None, ge=0)
    replan_count: int | None = Field(default=None, ge=0)
    termination_reason: str | None = None
    loop_state: str | None = None
    state_transition: str | None = None
    action_fingerprint: str | None = None
    fingerprint_repeat_count: int | None = Field(default=None, ge=0)
    reason_no_progress: str | None = None


class ProviderValidationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: ProviderName
    api_key: str = Field(min_length=10)


class ProviderValidationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: ProviderName
    valid: bool
    reason: str | None = None
    account_hint: str | None = None


class ProviderStatusResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: ProviderName
    key_configured: bool
    model_simple: str
    model_complex: str
    health: bool
