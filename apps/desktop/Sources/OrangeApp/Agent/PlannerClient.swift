import Foundation

struct PlanRequest: Codable {
    let schemaVersion: Int
    let sessionId: String
    let transcript: String
    let screenshotBase64: String?
    let axTreeSummary: String?
    let loopContext: LoopContext?
    let app: AppMetadata
    let preferences: PlannerPreferences?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case transcript
        case screenshotBase64 = "screenshot_base64"
        case axTreeSummary = "ax_tree_summary"
        case loopContext = "loop_context"
        case app
        case preferences
    }
}

struct LoopActionOutcome: Codable {
    let actionId: String
    let kind: String
    let status: String
    let errorCode: String?
    let actionHint: String?

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case kind
        case status
        case errorCode = "error_code"
        case actionHint = "action_hint"
    }
}

struct LoopContext: Codable {
    let goalTranscript: String
    let cycleIndex: Int
    let replanCount: Int
    let maxCycles: Int
    let maxReplans: Int
    let currentState: String?
    let nextRequiredState: String?
    let lastState: String?
    let lastVerifyStatus: String?
    let lastVerifyReason: String?
    let recentActionResults: [LoopActionOutcome]

    enum CodingKeys: String, CodingKey {
        case goalTranscript = "goal_transcript"
        case cycleIndex = "cycle_index"
        case replanCount = "replan_count"
        case maxCycles = "max_cycles"
        case maxReplans = "max_replans"
        case currentState = "current_state"
        case nextRequiredState = "next_required_state"
        case lastState = "last_state"
        case lastVerifyStatus = "last_verify_status"
        case lastVerifyReason = "last_verify_reason"
        case recentActionResults = "recent_action_results"
    }
}

struct PlanSimulationRequest: Codable {
    let schemaVersion: Int
    let sessionId: String
    let transcript: String
    let app: AppMetadata
    let preferences: PlannerPreferences?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case transcript
        case app
        case preferences
    }
}

struct PlannerPreferences: Codable {
    let preferredModel: String?
    let locale: String?
    let lowLatency: Bool

    enum CodingKeys: String, CodingKey {
        case preferredModel = "preferred_model"
        case locale
        case lowLatency = "low_latency"
    }
}

struct PlannerStreamEvent: Codable, Identifiable {
    let sessionId: String
    let event: String
    let message: String
    let progress: Int?
    let stepId: String?
    let severity: String?
    let timestamp: String?

    var id: String {
        "\(sessionId)-\(stepId ?? "none")-\(event)-\(message)-\(progress ?? -1)"
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case event
        case message
        case progress
        case stepId = "step_id"
        case severity
        case timestamp
    }
}

struct VerifyResponse: Codable {
    let schemaVersion: Int
    let sessionId: String
    let status: String
    let confidence: Double
    let reason: String?
    let state: String?
    let requiredTransition: String?
    let stateReason: String?
    let correctiveActions: [AgentAction]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case status
        case confidence
        case reason
        case state
        case requiredTransition = "required_transition"
        case stateReason = "state_reason"
        case correctiveActions = "corrective_actions"
    }
}

struct PlanSimulationResponse: Codable {
    let schemaVersion: Int
    let sessionId: String
    let isValid: Bool
    let parseErrors: [String]
    let riskLevel: String
    let requiresConfirmation: Bool
    let summary: String
    let proposedActionsCount: Int
    let recoveryGuidance: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case isValid = "is_valid"
        case parseErrors = "parse_errors"
        case riskLevel = "risk_level"
        case requiresConfirmation = "requires_confirmation"
        case summary
        case proposedActionsCount = "proposed_actions_count"
        case recoveryGuidance = "recovery_guidance"
    }
}

struct PlannerModelRoute: Codable {
    let app: String?
    let model: String
    let reason: String
}

struct ModelsResponse: Codable {
    let schemaVersion: Int
    let routing: [PlannerModelRoute]
    let featureFlags: [String: String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case routing
        case featureFlags = "feature_flags"
    }
}

struct ProviderStatusResponse: Codable {
    let provider: String
    let keyConfigured: Bool
    let modelSimple: String
    let modelComplex: String
    let health: Bool

    enum CodingKeys: String, CodingKey {
        case provider
        case keyConfigured = "key_configured"
        case modelSimple = "model_simple"
        case modelComplex = "model_complex"
        case health
    }
}

struct ProviderValidateRequest: Codable {
    let provider: String
    let apiKey: String

    enum CodingKeys: String, CodingKey {
        case provider
        case apiKey = "api_key"
    }
}

struct ProviderValidateResponse: Codable {
    let provider: String
    let valid: Bool
    let reason: String?
    let accountHint: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case valid
        case reason
        case accountHint = "account_hint"
    }
}

protocol PlannerClient {
    func plan(request: PlanRequest) async throws -> ActionPlan
    func simulate(request: PlanSimulationRequest) async throws -> PlanSimulationResponse
    func models() async throws -> ModelsResponse
    func providerStatus() async throws -> ProviderStatusResponse
    func validateProvider(request: ProviderValidateRequest) async throws -> ProviderValidateResponse
    func telemetry(event: SessionTelemetryEvent) async
    func verify(
        sessionId: String,
        plan: ActionPlan,
        executionStatus: ExecutionStatus,
        failedActionId: String?,
        completedActions: [String],
        reason: String?,
        loopContext: LoopContext?,
        beforeContext: String?,
        afterContext: String?
    ) async throws -> VerifyResponse
    func streamEvents(sessionId: String) -> AsyncThrowingStream<PlannerStreamEvent, Error>
}

enum PlannerServiceError: LocalizedError {
    case server(message: String, errorCode: String?)

    var errorDescription: String? {
        switch self {
        case let .server(message, _):
            return message
        }
    }

    var code: String? {
        switch self {
        case let .server(_, errorCode):
            return errorCode
        }
    }
}
