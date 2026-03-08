import Foundation

final class HTTPPlannerClient: PlannerClient {
    private let baseURL: URL
    private let session: URLSession
    private let telemetrySession: URLSession
    private let planningRequestTimeout: TimeInterval
    private let providerValidationTimeout: TimeInterval
    private let telemetryTimeout: TimeInterval

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:7789")!,
        session: URLSession? = nil,
        planningRequestTimeout: TimeInterval = 90.0,
        providerValidationTimeout: TimeInterval = 30.0,
        telemetryTimeout: TimeInterval = 2.0
    ) {
        self.baseURL = baseURL
        if let session {
            self.session = session
            self.telemetrySession = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = planningRequestTimeout
            configuration.timeoutIntervalForResource = 300.0
            self.session = URLSession(configuration: configuration)

            let telemetryConfiguration = URLSessionConfiguration.ephemeral
            telemetryConfiguration.timeoutIntervalForRequest = telemetryTimeout
            telemetryConfiguration.timeoutIntervalForResource = telemetryTimeout
            self.telemetrySession = URLSession(configuration: telemetryConfiguration)
        }
        self.planningRequestTimeout = planningRequestTimeout
        self.providerValidationTimeout = providerValidationTimeout
        self.telemetryTimeout = telemetryTimeout
    }

    func plan(request: PlanRequest) async throws -> ActionPlan {
        let endpoint = baseURL.appendingPathComponent("/v1/plan")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = planningRequestTimeout

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseServerDetail(from: data)
            throw PlannerServiceError.server(
                message: detail?.message ?? "Planning request failed (HTTP \(httpResponse.statusCode))",
                errorCode: detail?.errorCode
            )
        }

        return try JSONDecoder().decode(ActionPlan.self, from: data)
    }

    func simulate(request: PlanSimulationRequest) async throws -> PlanSimulationResponse {
        let endpoint = baseURL.appendingPathComponent("/v1/plan/simulate")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = planningRequestTimeout

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseServerDetail(from: data)
            throw PlannerServiceError.server(
                message: detail?.message ?? "Plan simulation failed (HTTP \(httpResponse.statusCode))",
                errorCode: detail?.errorCode
            )
        }

        return try JSONDecoder().decode(PlanSimulationResponse.self, from: data)
    }

    func models() async throws -> ModelsResponse {
        let endpoint = baseURL.appendingPathComponent("/v1/models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = planningRequestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data)
    }

    func providerStatus() async throws -> ProviderStatusResponse {
        let endpoint = baseURL.appendingPathComponent("/v1/provider/status")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = planningRequestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseServerDetail(from: data)
            throw PlannerServiceError.server(
                message: detail?.message ?? "Failed to fetch provider status (HTTP \(httpResponse.statusCode))",
                errorCode: detail?.errorCode
            )
        }
        return try JSONDecoder().decode(ProviderStatusResponse.self, from: data)
    }

    func validateProvider(request payload: ProviderValidateRequest) async throws -> ProviderValidateResponse {
        let endpoint = baseURL.appendingPathComponent("/v1/provider/validate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = providerValidationTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseServerDetail(from: data)
            throw PlannerServiceError.server(
                message: detail?.message ?? "Provider validation failed (HTTP \(httpResponse.statusCode))",
                errorCode: detail?.errorCode
            )
        }
        return try JSONDecoder().decode(ProviderValidateResponse.self, from: data)
    }

    func telemetry(event: SessionTelemetryEvent) async {
        do {
            let endpoint = baseURL.appendingPathComponent("/v1/telemetry")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(event)
            request.timeoutInterval = telemetryTimeout
            _ = try await telemetrySession.data(for: request)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                Logger.info("Telemetry skipped: sidecar busy")
            } else {
                Logger.info("Telemetry skipped: \(error.localizedDescription)")
            }
        }
    }

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
    ) async throws -> VerifyResponse {
        let payload = VerifyRequestPayload(
            schemaVersion: 1,
            sessionId: sessionId,
            actionPlan: plan,
            executionResult: executionStatus,
            failedActionId: failedActionId,
            completedActions: completedActions,
            loopContext: loopContext,
            reason: reason,
            beforeContext: beforeContext,
            afterContext: afterContext
        )

        let endpoint = baseURL.appendingPathComponent("/v1/verify")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = planningRequestTimeout

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let detail = parseServerDetail(from: data)
            throw PlannerServiceError.server(
                message: detail?.message ?? "Verification request failed (HTTP \(httpResponse.statusCode))",
                errorCode: detail?.errorCode
            )
        }

        return try JSONDecoder().decode(VerifyResponse.self, from: data)
    }

    func streamEvents(sessionId: String) -> AsyncThrowingStream<PlannerStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let endpoint = baseURL.appendingPathComponent("/v1/events/\(sessionId)")
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "GET"
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 0

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ... 299).contains(httpResponse.statusCode) else {
                        throw URLError(.badServerResponse)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.replacingOccurrences(of: "data:", with: "").trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let event = try? JSONDecoder().decode(PlannerStreamEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private struct ServerErrorDetail {
    let message: String
    let errorCode: String?
}

private func parseServerDetail(from data: Data) -> ServerErrorDetail? {
    guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    if let detail = payload["detail"] as? [String: Any],
       let message = detail["message"] as? String {
        return ServerErrorDetail(message: message, errorCode: detail["error_code"] as? String)
    }
    if let detail = payload["detail"] as? String {
        return ServerErrorDetail(message: detail, errorCode: nil)
    }
    if let details = payload["detail"] as? [[String: Any]],
       let first = details.first {
        let message = (first["msg"] as? String) ?? "Request validation failed"
        let loc = (first["loc"] as? [Any])?
            .map { String(describing: $0) }
            .joined(separator: ".")
        let composed = loc.map { "\(message) at \($0)" } ?? message
        return ServerErrorDetail(message: composed, errorCode: nil)
    }
    return nil
}

private struct VerifyRequestPayload: Codable {
    let schemaVersion: Int
    let sessionId: String
    let actionPlan: ActionPlan
    let executionResult: ExecutionStatus
    let failedActionId: String?
    let completedActions: [String]
    let loopContext: LoopContext?
    let reason: String?
    let beforeContext: String?
    let afterContext: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionId = "session_id"
        case actionPlan = "action_plan"
        case executionResult = "execution_result"
        case failedActionId = "failed_action_id"
        case completedActions = "completed_actions"
        case loopContext = "loop_context"
        case reason
        case beforeContext = "before_context"
        case afterContext = "after_context"
    }
}
