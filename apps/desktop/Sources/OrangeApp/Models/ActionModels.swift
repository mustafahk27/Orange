import Foundation

enum ActionKind: String, Codable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case type
    case keyCombo = "key_combo"
    case scroll
    case openApp = "open_app"
    case runAppleScript = "run_applescript"
    case selectMenuItem = "select_menu_item"
    case wait
}

struct AgentAction: Codable, Hashable, Identifiable {
    let id: String
    let kind: ActionKind
    let target: String?
    let text: String?
    let keyCombo: String?
    let appBundleId: String?
    let timeoutMs: Int
    let destructive: Bool
    let expectedOutcome: String?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case target
        case text
        case keyCombo = "key_combo"
        case appBundleId = "app_bundle_id"
        case timeoutMs = "timeout_ms"
        case destructive
        case expectedOutcome = "expected_outcome"
    }
}

struct ActionPlan: Codable {
    let schemaVersion: Int
    let sessionId: String
    let actions: [AgentAction]
    let confidence: Double
    let riskLevel: String
    let requiresConfirmation: Bool
    let summary: String?
    let goalState: String?
    let plannerNote: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case actions
        case confidence
        case riskLevel = "risk_level"
        case requiresConfirmation = "requires_confirmation"
        case summary
        case goalState = "goal_state"
        case plannerNote = "planner_note"
    }
}

enum ExecutionStatus: String, Codable {
    case success
    case failure
    case partial
}

enum ActionExecutionStatus: String, Codable {
    case success
    case failure
    case skipped
}

struct ActionExecutionRecord: Codable, Hashable {
    let id: String
    let status: ActionExecutionStatus
    let errorCode: String?
    let latencyMs: Int

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case errorCode = "error_code"
        case latencyMs = "latency_ms"
    }
}

struct ExecutionResult: Codable {
    let status: ExecutionStatus
    let completedActions: [String]
    let failedActionId: String?
    let reason: String?
    let recoverySuggestion: String?
    let actionResults: [ActionExecutionRecord]

    enum CodingKeys: String, CodingKey {
        case status
        case completedActions = "completed_actions"
        case failedActionId = "failed_action_id"
        case reason
        case recoverySuggestion = "recovery_suggestion"
        case actionResults = "action_results"
    }
}

struct SessionTelemetryEvent: Codable {
    let sessionId: String
    let timestamp: String
    let stage: String
    let app: String?
    let actionKind: String?
    let status: String
    let latencyMs: Int?
    let errorCode: String?
    let cycleIndex: Int?
    let replanCount: Int?
    let terminationReason: String?
    let loopState: String?
    let stateTransition: String?
    let actionFingerprint: String?
    let fingerprintRepeatCount: Int?
    let reasonNoProgress: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case timestamp
        case stage
        case app
        case actionKind = "action_kind"
        case status
        case latencyMs = "latency_ms"
        case errorCode = "error_code"
        case cycleIndex = "cycle_index"
        case replanCount = "replan_count"
        case terminationReason = "termination_reason"
        case loopState = "loop_state"
        case stateTransition = "state_transition"
        case actionFingerprint = "action_fingerprint"
        case fingerprintRepeatCount = "fingerprint_repeat_count"
        case reasonNoProgress = "reason_no_progress"
    }
}

struct SafetyDecisionRecord: Codable, Identifiable, Hashable {
    let id: String
    let sessionId: String
    let category: String
    let decision: String
    let timestamp: String
    let approvalMode: String

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case category
        case decision
        case timestamp
        case approvalMode = "approval_mode"
    }
}
