import CryptoKit
import Foundation

@MainActor
final class SessionManager {
    private enum LoopState: String {
        case appActive = "APP_ACTIVE"
        case uiContextChanged = "UI_CONTEXT_CHANGED"
        case editorOpen = "EDITOR_OPEN"
        case fieldFocused = "FIELD_FOCUSED"
        case dataEntered = "DATA_ENTERED"
        case commitAttempted = "COMMIT_ATTEMPTED"
        case completed = "COMPLETED"
        case blocked = "BLOCKED"
    }

    private struct LoopRuntime {
        let goalTranscript: String
        let maxCycles: Int
        let maxReplans: Int
        var cycleIndex: Int
        var replanCount: Int
        var currentState: String?
        var nextRequiredState: String?
        var lastState: String?
        var lastVerifyStatus: String?
        var lastVerifyReason: String?
        var lastVerifyState: String?
        var lastVerifyRequiredTransition: String?
        var lastVerifyStateReason: String?
        var recentActionResults: [LoopActionOutcome]
        var lastActionFingerprint: String?
        var repeatedNoProgressFingerprintCount: Int
        var lastNoProgressReason: String?
    }

    private enum LoopTerminationReason: String {
        case complete
        case blocked
        case budgetExhausted = "budget_exhausted"
        case verificationFailed = "verification_failed"
        case planningFailed = "planning_failed"
    }

    private let sttService: SpeechToTextService
    private let contextProvider: ContextProvider
    private let plannerClient: PlannerClient
    private let executionEngine: ExecutionEngine
    private let safetyPolicy: SafetyPolicy

    private(set) var pendingPlan: ActionPlan?
    private var pendingAllowCorrectiveRetry = true
    private var eventStreamTask: Task<Void, Never>?
    private var executionTask: Task<ExecutionResult, Never>?
    private var canceled = false
    private var sessionApprovals = Set<SafetyCategory>()
    private var loopRuntime: LoopRuntime?
    private let timestampFormatter = ISO8601DateFormatter()
    private static let defaultTranscribeConfidence = 0.58

    init(
        sttService: SpeechToTextService,
        contextProvider: ContextProvider,
        plannerClient: PlannerClient,
        executionEngine: ExecutionEngine,
        safetyPolicy: SafetyPolicy
    ) {
        self.sttService = sttService
        self.contextProvider = contextProvider
        self.plannerClient = plannerClient
        self.executionEngine = executionEngine
        self.safetyPolicy = safetyPolicy
    }

    private static var asrConfidenceThreshold: Double {
        let raw = ProcessInfo.processInfo.environment["ORANGE_ASR_CONFIDENCE_MIN"] ?? String(defaultTranscribeConfidence)
        let parsed = Double(raw)
        return max(0, min(1, parsed ?? defaultTranscribeConfidence))
    }

    func beginRecording(state: AppState) {
        cleanupActiveWork(state: state, resetStatus: false)
        canceled = false
        sessionApprovals = []
        state.sessionId = UUID().uuidString
        sttService.setPartialHandler { partial in
            Task { @MainActor in
                state.partialTranscript = partial
            }
        }
        state.state = .listening
        state.statusText = "Listening..."
        state.partialTranscript = ""
        state.transcript = ""
        state.plannerEvents = []
        sttService.start()
        submitTelemetry(
            state: state,
            stage: "listening",
            status: "started"
        )
    }

    func stopRecordingAndPlan(state: AppState) async {
        guard !canceled else { return }
        state.state = .transcribing
        state.statusText = "Transcribing..."
        submitTelemetry(
            state: state,
            stage: "transcribing",
            status: "started"
        )

        startEventStreamIfNeeded(state: state)

        do {
            let transcriptResult = try await sttService.stop()
            guard !canceled else { return }
            state.transcript = transcriptResult.fullText
            state.partialTranscript = transcriptResult.fullText
            state.actionPlan = nil
            state.executionResult = nil

            let transcriptConfidence = transcriptResult.confidence
            let minConfidence = Self.asrConfidenceThreshold
            let normalizedTranscript = transcriptResult.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            let transcriptWordCount = normalizedTranscript.split(whereSeparator: \.isWhitespace).count
            let lowConfidenceBypassFloor = max(0.35, minConfidence - 0.20)
            let shouldBypassLowConfidence = (
                transcriptConfidence >= lowConfidenceBypassFloor &&
                transcriptWordCount >= 4 &&
                normalizedTranscript.count >= 16
            )

            guard transcriptConfidence >= minConfidence || shouldBypassLowConfidence else {
                state.state = .failed
                state.statusText = "I couldn’t capture your command clearly (\(String(format: "%.2f", transcriptConfidence))). Please speak again."
                submitTelemetry(
                    state: state,
                    stage: "planning",
                    status: "failed",
                    errorCode: "low_transcript_confidence"
                )
                eventStreamTask?.cancel()
                eventStreamTask = nil
                return
            }

            if transcriptConfidence < minConfidence {
                Logger.info(
                    "Proceeding with low transcript confidence \(String(format: "%.2f", transcriptConfidence)); threshold \(String(format: "%.2f", minConfidence)); words=\(transcriptWordCount)"
                )
                submitTelemetry(
                    state: state,
                    stage: "planning",
                    status: "warning",
                    errorCode: "low_transcript_confidence_bypassed"
                )
            }

            loopRuntime = LoopRuntime(
                goalTranscript: transcriptResult.fullText,
                maxCycles: 10,
                maxReplans: 4,
                cycleIndex: 0,
                replanCount: 0,
                currentState: nil,
                nextRequiredState: nil,
                lastState: nil,
                lastVerifyStatus: nil,
                lastVerifyReason: nil,
                lastVerifyState: nil,
                lastVerifyRequiredTransition: nil,
                lastVerifyStateReason: nil,
                recentActionResults: [],
                lastActionFingerprint: nil,
                repeatedNoProgressFingerprintCount: 0,
                lastNoProgressReason: nil
            )

            await planAndMaybeExecuteNextCycle(state: state)
        } catch is CancellationError {
            state.state = .canceled
            state.statusText = "Canceled"
            submitTelemetry(
                state: state,
                stage: "session",
                status: "canceled"
            )
            eventStreamTask?.cancel()
            eventStreamTask = nil
        } catch {
            if canceled {
                state.state = .canceled
                state.statusText = "Canceled"
                return
            }
            if let plannerError = error as? PlannerServiceError,
               let code = plannerError.code,
               code == "missing_api_key" || code == "invalid_api_key" || code == "invalid_api_key_format"
            {
                state.onboardingGate = .needsAPIKey
                state.sidecarHealthy = false
                state.state = .failed
                state.statusText = "Anthropic API key required. Open API Key Setup."
                submitTelemetry(
                    state: state,
                    stage: "planning",
                    status: "failed",
                    errorCode: code
                )
                eventStreamTask?.cancel()
                eventStreamTask = nil
                return
            }
            await failLoop(
                state: state,
                reason: .planningFailed,
                message: "Failed: \(error.localizedDescription)",
                errorCode: "planning_error"
            )
        }
    }

    func confirmAndExecute(state: AppState) async {
        guard let plan = pendingPlan else { return }
        let allowCorrectiveRetry = pendingAllowCorrectiveRetry
        recordSafetyDecisions(state: state, decision: "approved")
        for prompt in state.safetyPrompts where prompt.approvalMode == .perSession {
            sessionApprovals.insert(prompt.category)
        }
        pendingPlan = nil
        pendingAllowCorrectiveRetry = true
        state.safetyPrompts = []
        submitTelemetry(
            state: state,
            stage: "confirming",
            status: "approved",
            cycleIndex: loopRuntime?.cycleIndex,
            replanCount: loopRuntime?.replanCount
        )
        await executeCycle(plan, state: state, allowCorrectiveRetry: allowCorrectiveRetry)
    }

    func cancel(state: AppState) {
        if !state.safetyPrompts.isEmpty {
            recordSafetyDecisions(state: state, decision: "denied")
        }
        cleanupActiveWork(state: state, resetStatus: true)
        submitTelemetry(
            state: state,
            stage: "session",
            status: "canceled"
        )
    }

    private func startEventStreamIfNeeded(state: AppState) {
        eventStreamTask?.cancel()
        eventStreamTask = Task {
            do {
                for try await event in plannerClient.streamEvents(sessionId: state.sessionId) {
                    await MainActor.run {
                        state.plannerEvents.append(event)
                        state.statusText = event.message
                    }
                }
            } catch {
                await MainActor.run {
                    if state.state == .planning {
                        state.statusText = "Planning..."
                    }
                }
            }
        }
    }

    private func planAndMaybeExecuteNextCycle(state: AppState) async {
        guard !canceled else { return }
        guard let runtime = loopRuntime else {
            await failLoop(state: state, reason: .planningFailed, message: "Loop runtime missing", errorCode: "planning_error")
            return
        }

        if runtime.cycleIndex >= runtime.maxCycles {
            await failLoop(
                state: state,
                reason: .budgetExhausted,
                message: budgetExhaustedMessage(runtime),
                errorCode: "budget_exhausted"
            )
            return
        }

        state.state = .planning
        state.statusText = "Planning next step (\(runtime.cycleIndex + 1)/\(runtime.maxCycles))..."
        submitTelemetry(
            state: state,
            stage: "planning",
            status: "started",
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount,
            loopState: runtime.currentState,
            stateTransition: runtime.nextRequiredState
        )

        let context = await contextProvider.capture()
        guard !canceled else { return }
        let request = PlanRequest(
            schemaVersion: 1,
            sessionId: state.sessionId,
            transcript: runtime.goalTranscript,
            screenshotBase64: context.screenshotBase64,
            axTreeSummary: context.axTreeSummary,
            loopContext: LoopContext(
                goalTranscript: runtime.goalTranscript,
                cycleIndex: runtime.cycleIndex,
                replanCount: runtime.replanCount,
                maxCycles: runtime.maxCycles,
                maxReplans: runtime.maxReplans,
                currentState: runtime.currentState,
                nextRequiredState: runtime.nextRequiredState,
                lastState: runtime.lastState,
                lastVerifyStatus: runtime.lastVerifyStatus,
                lastVerifyReason: runtime.lastVerifyReason,
                recentActionResults: runtime.recentActionResults
            ),
            app: context.app,
            preferences: PlannerPreferences(preferredModel: nil, locale: nil, lowLatency: true)
        )

        let plan: ActionPlan
        do {
            plan = try await plannerClient.plan(request: request)
        } catch {
            await failLoop(
                state: state,
                reason: .planningFailed,
                message: "Failed: \(error.localizedDescription)",
                errorCode: "planning_error"
            )
            return
        }

        guard !canceled else { return }
        loopRuntime = runtime
        Logger.info(
            "Loop cycle \(runtime.cycleIndex + 1)/\(runtime.maxCycles) planned: summary='\(plan.summary ?? "n/a")' signature='\(planSignature(plan))' goalState='\(plan.goalState ?? "n/a")'"
        )
        state.actionPlan = plan

        let goalState = (plan.goalState ?? "in_progress").lowercased()
        if goalState == "complete" {
            finishLoopSuccess(state: state, message: plan.plannerNote ?? "Done")
            return
        }
        if goalState == "blocked" {
            await failLoop(
                state: state,
                reason: .blocked,
                message: "Failed: \(plan.plannerNote ?? "blocked")",
                errorCode: "blocked"
            )
            return
        }
        if plan.actions.isEmpty {
            await failLoop(
                state: state,
                reason: .blocked,
                message: "Failed: blocked",
                errorCode: "blocked"
            )
            return
        }

        let prompts = promptsForPlan(plan)
        if prompts.isEmpty {
            submitTelemetry(
                state: state,
                stage: "planning",
                status: "completed",
                cycleIndex: runtime.cycleIndex,
                replanCount: runtime.replanCount
            )
            await executeCycle(plan, state: state, allowCorrectiveRetry: true)
            return
        }

        pendingPlan = plan
        pendingAllowCorrectiveRetry = true
        state.safetyPrompts = prompts
        state.state = .confirming
        state.statusText = "Confirmation required"
        submitTelemetry(
            state: state,
            stage: "confirming",
            status: "required",
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount
        )
        loopRuntime = runtime
    }

    private func executeCycle(_ plan: ActionPlan, state: AppState, allowCorrectiveRetry: Bool) async {
        guard !canceled else { return }
        guard var runtime = loopRuntime else {
            await failLoop(state: state, reason: .planningFailed, message: "Loop runtime missing", errorCode: "planning_error")
            return
        }
        loopRuntime = runtime

        state.state = .executing
        state.statusText = "Executing cycle \(runtime.cycleIndex + 1)..."
        submitTelemetry(
            state: state,
            stage: "executing",
            status: "started",
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount
        )

        let beforeContext = await contextProvider.capture()
        guard !canceled else { return }
        let normalizedPlan = normalizePlanAgainstCurrentContext(plan: plan, context: beforeContext)
        let actionFingerprint = planActionFingerprint(plan: normalizedPlan, context: beforeContext)
        let beforeDigest = contextDigest(from: beforeContext)
        let beforeLoopContext = LoopContext(
            goalTranscript: runtime.goalTranscript,
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount,
            maxCycles: runtime.maxCycles,
            maxReplans: runtime.maxReplans,
            currentState: runtime.currentState,
            nextRequiredState: runtime.nextRequiredState,
            lastState: runtime.lastState,
            lastVerifyStatus: runtime.lastVerifyStatus,
            lastVerifyReason: runtime.lastVerifyReason,
            recentActionResults: runtime.recentActionResults
        )

        executionTask?.cancel()

        let result: ExecutionResult
        if normalizedPlan.actions.isEmpty {
            result = ExecutionResult(
                status: .failure,
                completedActions: [],
                failedActionId: nil,
                reason: "No executable actions after pruning redundant open_app step",
                recoverySuggestion: "Replan",
                actionResults: []
            )
        } else {
            executionTask = Task { [executionEngine] in
                await executionEngine.execute(plan: normalizedPlan)
            }
            result = await (executionTask?.value ?? ExecutionResult(
                status: .failure,
                completedActions: [],
                failedActionId: nil,
                reason: "Execution task cancelled",
                recoverySuggestion: "Retry",
                actionResults: []
            ))
            executionTask = nil
        }

        if normalizedPlan.actions.isEmpty {
            Logger.info("Pruned plan to zero actions (likely redundant open_app). Triggering replan via verify path.")
        }

        let effectivePlan = normalizedPlan
        Logger.info(
            "Execution cycle \(runtime.cycleIndex + 1) finished: status='\(result.status.rawValue)' completed=\(result.completedActions.count) failedAction='\(result.failedActionId ?? "none")' reason='\(result.reason ?? "n/a")'"
        )

        state.executionResult = result

        let actionKindsById = Dictionary(uniqueKeysWithValues: effectivePlan.actions.map { ($0.id, $0.kind.rawValue) })
        let actionsById = Dictionary(uniqueKeysWithValues: effectivePlan.actions.map { ($0.id, $0) })
        runtime.recentActionResults = result.actionResults.map {
            LoopActionOutcome(
                actionId: $0.id,
                kind: actionKindsById[$0.id] ?? "unknown",
                status: $0.status.rawValue,
                errorCode: $0.errorCode,
                actionHint: actionsById[$0.id].map(actionHint)
            )
        }

        for actionResult in result.actionResults {
            submitTelemetry(
                state: state,
                stage: "executing",
                actionKind: actionKindsById[actionResult.id],
                status: actionResult.status.rawValue,
                latencyMs: actionResult.latencyMs,
                errorCode: actionResult.errorCode,
                cycleIndex: runtime.cycleIndex,
                replanCount: runtime.replanCount
            )
        }

        state.state = .verifying
        state.statusText = "Verifying cycle \(runtime.cycleIndex + 1)..."
        submitTelemetry(
            state: state,
            stage: "verifying",
            status: "started",
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount,
            loopState: runtime.currentState,
            stateTransition: runtime.nextRequiredState
        )

        let afterContext = await contextProvider.capture()
        guard !canceled else { return }
        let verifyResult = try? await plannerClient.verify(
            sessionId: state.sessionId,
            plan: plan,
            executionStatus: result.status,
            failedActionId: result.failedActionId,
            completedActions: result.completedActions,
            reason: result.reason,
            loopContext: beforeLoopContext,
            beforeContext: beforeDigest,
            afterContext: contextDigest(from: afterContext)
        )

        let verification = evaluateVerificationResult(
            result: result,
            runtime: &runtime,
            verifyResult: verifyResult,
            actionFingerprint: actionFingerprint
        )
        let verifyFailed = verification.failed
        runtime.lastVerifyStatus = verifyFailed ? "failure" : "success"
        runtime.lastVerifyReason = verification.reason
        runtime.lastVerifyState = verification.observedState
        runtime.lastVerifyRequiredTransition = verification.requiredTransition
        runtime.lastVerifyStateReason = verification.stateReason
        Logger.info(
            "Verify cycle \(runtime.cycleIndex + 1): failed=\(verifyFailed) reason='\(runtime.lastVerifyReason ?? "n/a")' state='\(verification.observedState ?? "n/a")' correctiveActions=\(verifyResult?.correctiveActions.count ?? 0) fingerprint=\(actionFingerprint)"
        )
        loopRuntime = runtime

        if !verifyFailed {
            runtime.cycleIndex += 1
            loopRuntime = runtime
            await planAndMaybeExecuteNextCycle(state: state)
            return
        }

        if verification.repeatedNoProgressBlocked {
            await failLoop(
                state: state,
                reason: .blocked,
                message: "Failed: repeated_no_progress - \(verification.reason ?? "No progress")",
                errorCode: "repeated_no_progress"
            )
            return
        }

        if allowCorrectiveRetry {
            var correctiveActions = verifyResult?.correctiveActions ?? []
            if correctiveActions.isEmpty {
                correctiveActions = deterministicFallbackActions(
                    for: plan,
                    runtime: runtime,
                    executionResult: result,
                    verifyResult: verifyResult
                )
            }
            correctiveActions = prependRefocusActionIfNeeded(
                correctiveActions,
                originalPlan: plan,
                failureReason: verification.reason ?? result.reason
            )

            if !correctiveActions.isEmpty {
                state.statusText = "Retrying corrective step..."
                submitTelemetry(
                    state: state,
                    stage: "verifying",
                    status: "loop_retry_corrective",
                    cycleIndex: runtime.cycleIndex,
                    replanCount: runtime.replanCount,
                    loopState: runtime.currentState,
                    stateTransition: verification.requiredTransition,
                    actionFingerprint: actionFingerprint,
                    fingerprintRepeatCount: runtime.repeatedNoProgressFingerprintCount,
                    reasonNoProgress: verification.noProgressReason
                )
                let correctivePlan = ActionPlan(
                    schemaVersion: plan.schemaVersion,
                    sessionId: plan.sessionId,
                    actions: correctiveActions,
                    confidence: verifyResult?.confidence ?? plan.confidence,
                    riskLevel: plan.riskLevel,
                    requiresConfirmation: plan.requiresConfirmation,
                    summary: "Corrective retry",
                    goalState: "in_progress",
                    plannerNote: verifyResult?.reason
                )
                let correctivePrompts = promptsForPlan(correctivePlan)
                if correctivePrompts.isEmpty {
                    await executeCycle(correctivePlan, state: state, allowCorrectiveRetry: false)
                } else {
                    pendingPlan = correctivePlan
                    pendingAllowCorrectiveRetry = false
                    state.safetyPrompts = correctivePrompts
                    state.state = .confirming
                    state.statusText = "Confirmation required"
                    submitTelemetry(
                        state: state,
                        stage: "confirming",
                        status: "required",
                        cycleIndex: runtime.cycleIndex,
                        replanCount: runtime.replanCount
                    )
                }
                return
            }
        }

        runtime.replanCount += 1
        if runtime.replanCount > runtime.maxReplans {
            loopRuntime = runtime
            await failLoop(
                state: state,
                reason: .budgetExhausted,
                message: budgetExhaustedMessage(runtime),
                errorCode: "budget_exhausted"
            )
            return
        }

        loopRuntime = runtime
        Logger.info(
            "Loop replan requested: cycle=\(runtime.cycleIndex + 1) replanCount=\(runtime.replanCount) lastReason='\(runtime.lastVerifyReason ?? "n/a")'"
        )
        submitTelemetry(
            state: state,
            stage: "planning",
            status: "loop_replan",
            cycleIndex: runtime.cycleIndex,
            replanCount: runtime.replanCount,
            loopState: runtime.currentState,
            stateTransition: verification.requiredTransition,
            actionFingerprint: actionFingerprint,
            fingerprintRepeatCount: runtime.repeatedNoProgressFingerprintCount,
            reasonNoProgress: verification.noProgressReason
        )
        await planAndMaybeExecuteNextCycle(state: state)
    }

    private func deterministicFallbackActions(
        for plan: ActionPlan,
        runtime: LoopRuntime,
        executionResult: ExecutionResult,
        verifyResult: VerifyResponse?
    ) -> [AgentAction] {
        guard runtime.repeatedNoProgressFingerprintCount > 0 else { return [] }
        guard let firstAction = plan.actions.first else { return [] }

        let isClickLike = firstAction.kind == .click || firstAction.kind == .doubleClick || firstAction.kind == .selectMenuItem
        guard isClickLike else {
            return []
        }
        _ = executionResult
        _ = verifyResult

        let repeatCount = runtime.repeatedNoProgressFingerprintCount
        let expectsCommit = runtime.nextRequiredState == LoopState.commitAttempted.rawValue
        switch firstAction.kind {
        case .doubleClick:
            let primary = AgentAction(
                id: "retry_1",
                kind: .keyCombo,
                target: nil,
                text: nil,
                keyCombo: repeatCount >= 2 && expectsCommit ? "cmd+s" : "return",
                appBundleId: nil,
                timeoutMs: 900,
                destructive: false,
                expectedOutcome: nil
            )
            let secondary = AgentAction(
                id: "retry_2",
                kind: .keyCombo,
                target: nil,
                text: nil,
                keyCombo: "tab",
                appBundleId: nil,
                timeoutMs: 900,
                destructive: false,
                expectedOutcome: nil
            )
            return [primary, secondary]
        case .click:
            let primary = AgentAction(
                id: "retry_1",
                kind: .keyCombo,
                target: nil,
                text: nil,
                keyCombo: "tab",
                appBundleId: nil,
                timeoutMs: 900,
                destructive: false,
                expectedOutcome: nil
            )
            let secondary: AgentAction
            if repeatCount >= 2 {
                secondary = AgentAction(
                    id: "retry_2",
                    kind: .keyCombo,
                    target: nil,
                    text: nil,
                    keyCombo: expectsCommit ? "cmd+s" : "return",
                    appBundleId: nil,
                    timeoutMs: 900,
                    destructive: false,
                    expectedOutcome: nil
                )
            } else {
                secondary = AgentAction(
                    id: "retry_2",
                    kind: .keyCombo,
                    target: nil,
                    text: nil,
                    keyCombo: "return",
                    appBundleId: nil,
                    timeoutMs: 900,
                    destructive: false,
                    expectedOutcome: nil
                )
            }
            return [primary, secondary]
        case .selectMenuItem:
            let primary = AgentAction(
                id: "retry_1",
                kind: .keyCombo,
                target: nil,
                text: nil,
                keyCombo: "esc",
                appBundleId: nil,
                timeoutMs: 900,
                destructive: false,
                expectedOutcome: nil
            )
            let secondary = AgentAction(
                id: "retry_2",
                kind: .keyCombo,
                target: nil,
                text: nil,
                keyCombo: "enter",
                appBundleId: nil,
                timeoutMs: 900,
                destructive: false,
                expectedOutcome: nil
            )
            return [primary, secondary]
        default:
            return []
        }
    }

    private func promptsForPlan(_ plan: ActionPlan) -> [SafetyPrompt] {
        var prompts = safetyPolicy
            .evaluate(actions: plan.actions)
            .filter { shouldPrompt($0) }

        let isHighRisk = plan.requiresConfirmation || plan.riskLevel == "high"
        if isHighRisk {
            prompts.append(
                SafetyPrompt(
                    category: .send,
                    approvalMode: .alwaysAsk,
                    title: "Confirm High-Risk Step",
                    message: "This loop cycle includes high-risk actions and requires approval."
                )
            )
        }
        return prompts
    }

    private func finishLoopSuccess(state: AppState, message: String) {
        state.state = .done
        state.statusText = message
        submitTelemetry(
            state: state,
            stage: "session",
            status: "success",
            cycleIndex: loopRuntime?.cycleIndex,
            replanCount: loopRuntime?.replanCount,
            terminationReason: LoopTerminationReason.complete.rawValue
        )
        loopRuntime = nil
        pendingPlan = nil
        state.safetyPrompts = []
        eventStreamTask?.cancel()
        eventStreamTask = nil
        Logger.info("Loop completed successfully: message='\(message)'")
    }

    private func failLoop(
        state: AppState,
        reason: LoopTerminationReason,
        message: String,
        errorCode: String
    ) async {
        state.state = .failed
        state.statusText = message
        Logger.error(
            "Loop failed: reason='\(reason.rawValue)' errorCode='\(errorCode)' cycle=\(loopRuntime?.cycleIndex ?? -1) replan=\(loopRuntime?.replanCount ?? -1) lastVerifyReason='\(loopRuntime?.lastVerifyReason ?? "n/a")' message='\(message)'"
        )
        submitTelemetry(
            state: state,
            stage: "session",
            status: "failure",
            errorCode: errorCode,
            cycleIndex: loopRuntime?.cycleIndex,
            replanCount: loopRuntime?.replanCount,
            terminationReason: reason.rawValue
        )
        loopRuntime = nil
        pendingPlan = nil
        pendingAllowCorrectiveRetry = true
        state.safetyPrompts = []
        eventStreamTask?.cancel()
        eventStreamTask = nil
    }

    private func contextDigest(from context: ScreenContext) -> String {
        let appName = context.app.name ?? "Unknown"
        let window = context.app.windowTitle ?? "Unknown"
        let url = context.app.url ?? "n/a"
        let axSummary = context.axTreeSummary ?? ""
        let axHead = String(axSummary.prefix(4000))
        let axTail = axSummary.count > 4000 ? String(axSummary.suffix(4000)) : axHead
        let axHash = SHA256.hash(data: Data(axSummary.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        let axLineCount = axSummary.split(separator: "\n", omittingEmptySubsequences: false).count
        return """
        app=\(appName), window=\(window), url=\(url), ax_lines=\(axLineCount), ax_sha256=\(axHash), ax_head=\(axHead), ax_tail=\(axTail)
        """
    }

    private func budgetExhaustedMessage(_ runtime: LoopRuntime) -> String {
        let lastReason = runtime.lastVerifyReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastReason, !lastReason.isEmpty {
            return "Failed: no progress after retries. Last reason: \(lastReason)"
        }
        return "Failed: budget_exhausted"
    }

    private func evaluateVerificationResult(
        result: ExecutionResult,
        runtime: inout LoopRuntime,
        verifyResult: VerifyResponse?,
        actionFingerprint: String
    ) -> VerificationSummary {
        var summary = VerificationSummary(
            failed: false,
            reason: verifyResult?.reason,
            observedState: verifyResult?.state,
            requiredTransition: verifyResult?.requiredTransition,
            stateReason: verifyResult?.stateReason,
            noProgressReason: nil,
            repeatedNoProgressBlocked: false
        )

        guard result.status == .success else {
            summary.failed = true
            summary.reason = result.reason ?? "Execution did not succeed"
            runtime.repeatedNoProgressFingerprintCount = 0
            runtime.lastActionFingerprint = actionFingerprint
            return summary
        }

        if verifyResult == nil {
            summary.failed = true
            summary.reason = "Verification service unavailable"
            summary.noProgressReason = "No verification result available"
            runtime.repeatedNoProgressFingerprintCount = 0
            runtime.lastActionFingerprint = actionFingerprint
            return summary
        }

        if verifyResult?.status == "failure" {
            summary.failed = true
            summary.reason = verifyResult?.reason ?? "Verifier reported failure"
            summary.noProgressReason = verifyResult?.stateReason
            runtime.lastActionFingerprint = actionFingerprint
        }

        if !summary.failed {
            let hasExpectedStateTransition = isExpectedStateTransitionSufficient(
                required: runtime.nextRequiredState,
                observed: verifyResult?.state
            )

            let hasObservedStateTransition: Bool
            if let observed = verifyResult?.state {
                hasObservedStateTransition = runtime.currentState == nil || observed != runtime.currentState
            } else {
                hasObservedStateTransition = false
            }

            if !hasExpectedStateTransition {
                summary.failed = true
                summary.noProgressReason = verifyResult?.stateReason
                summary.reason = verifyResult?.stateReason ?? "Unexpected verifier state"
            } else if !hasObservedStateTransition && runtime.currentState != nil {
                summary.failed = true
                summary.noProgressReason = verifyResult?.stateReason
                if let noReason = verifyResult?.stateReason, !noReason.isEmpty {
                    summary.reason = noReason
                } else {
                    summary.reason = "No meaningful state transition"
                }
            }
        }

        if summary.failed {
            if runtime.lastActionFingerprint == actionFingerprint && runtime.lastNoProgressReason == summary.noProgressReason {
                runtime.repeatedNoProgressFingerprintCount += 1
            } else {
                runtime.repeatedNoProgressFingerprintCount = 1
            }

            runtime.lastNoProgressReason = summary.noProgressReason
            runtime.lastActionFingerprint = actionFingerprint

            if runtime.repeatedNoProgressFingerprintCount >= 2 {
                summary.repeatedNoProgressBlocked = true
            }
            return summary
        }

        runtime.lastNoProgressReason = nil
        runtime.repeatedNoProgressFingerprintCount = 0

        if let observedState = verifyResult?.state {
            runtime.lastState = runtime.currentState
            runtime.currentState = observedState
            runtime.nextRequiredState = inferredNextRequiredState(from: observedState)
        }
        runtime.lastActionFingerprint = actionFingerprint

        return summary
    }

    private func inferredNextRequiredState(from observedState: String?) -> String? {
        guard let observedState else { return nil }
        switch observedState {
        case LoopState.appActive.rawValue:
            return LoopState.uiContextChanged.rawValue
        case LoopState.uiContextChanged.rawValue:
            return LoopState.fieldFocused.rawValue
        case LoopState.fieldFocused.rawValue:
            return LoopState.dataEntered.rawValue
        case LoopState.dataEntered.rawValue:
            return LoopState.commitAttempted.rawValue
        case LoopState.commitAttempted.rawValue:
            return LoopState.completed.rawValue
        default:
            return LoopState.completed.rawValue
        }
    }

    private func isExpectedStateTransitionSufficient(required: String?, observed: String?) -> Bool {
        guard let required else { return true }
        guard let observed else { return false }
        if observed == required { return true }

        guard let requiredRank = stateRank(required), let observedRank = stateRank(observed) else {
            return false
        }
        return observedRank >= requiredRank
    }

    private func stateRank(_ rawState: String) -> Int? {
        switch rawState {
        case LoopState.appActive.rawValue:
            return 0
        case LoopState.uiContextChanged.rawValue:
            return 1
        case LoopState.editorOpen.rawValue:
            return 2
        case LoopState.fieldFocused.rawValue:
            return 3
        case LoopState.dataEntered.rawValue:
            return 4
        case LoopState.commitAttempted.rawValue:
            return 5
        case LoopState.completed.rawValue, LoopState.blocked.rawValue:
            return 6
        default:
            return nil
        }
    }

    private func planSignature(_ plan: ActionPlan) -> String {
        plan.actions
            .prefix(3)
            .map { action in
                let value: String
                switch action.kind {
                case .type, .runAppleScript:
                    value = String((action.text ?? "").prefix(80))
                case .keyCombo:
                    value = action.keyCombo ?? ""
                default:
                    value = action.target ?? ""
                }
                return "\(action.kind.rawValue):\(value)"
            }
            .joined(separator: " | ")
    }

    private func actionFingerprint(_ action: AgentAction) -> String {
        switch action.kind {
        case .type, .runAppleScript:
            return String((action.text ?? "").prefix(120))
        case .keyCombo:
            return action.keyCombo ?? ""
        default:
            return action.target ?? action.appBundleId ?? ""
        }
    }

    private func actionContextFingerprint(from context: ScreenContext) -> String {
        let appName = context.app.name ?? "unknown"
        let window = context.app.windowTitle ?? "unknown"
        let url = context.app.url ?? "n/a"
        let signature = "\(appName)|\(window)|\(url)"
        return signature
    }

    private func planActionFingerprint(plan: ActionPlan, context: ScreenContext) -> String {
        let actionSignature = plan.actions
            .prefix(3)
            .map { action in
                "\(action.kind.rawValue):\(actionFingerprint(action))"
            }
            .joined(separator: "|")

        let seed = "\(actionSignature)|\(actionContextFingerprint(from: context))"
        let hashed = SHA256.hash(data: Data(seed.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return hashed
    }

    private func normalizePlanAgainstCurrentContext(plan: ActionPlan, context: ScreenContext) -> ActionPlan {
        guard let firstAction = plan.actions.first,
              firstAction.kind == .openApp,
              isRedundantOpenApp(firstAction, context: context)
        else {
            return plan
        }

        // Keep open_app when subsequent actions need a focused app context.
        // Pruning it in those cases can cause "Focused app unavailable" failures.
        let remainingActions = Array(plan.actions.dropFirst())
        if remainingActions.contains(where: requiresFocusedAppContext) {
            return plan
        }

        let reducedActions = remainingActions
        Logger.info("Filtered redundant open_app for active app '\(activeAppSignature(from: context))'")

        return ActionPlan(
            schemaVersion: plan.schemaVersion,
            sessionId: plan.sessionId,
            actions: reducedActions,
            confidence: plan.confidence,
            riskLevel: plan.riskLevel,
            requiresConfirmation: plan.requiresConfirmation,
            summary: plan.summary,
            goalState: plan.goalState,
            plannerNote: plan.plannerNote
        )
    }

    private func isRedundantOpenApp(_ action: AgentAction, context: ScreenContext) -> Bool {
        let target = normalizedAppToken(action.target)
        let targetBundle = normalizedAppToken(action.appBundleId)
        let activeName = normalizedAppToken(context.app.name)
        let activeBundle = normalizedAppToken(context.app.bundleId)

        guard !activeName.isEmpty || !activeBundle.isEmpty else {
            return false
        }

        if !targetBundle.isEmpty {
            if targetBundle == activeBundle || targetBundle.contains(activeBundle) || activeBundle.contains(targetBundle) {
                return true
            }
        }
        if !target.isEmpty {
            if target == activeName || target.contains(activeName) || activeName.contains(target) {
                return true
            }
        }
        return false
    }

    private func requiresFocusedAppContext(_ action: AgentAction) -> Bool {
        switch action.kind {
        case .click, .doubleClick, .selectMenuItem, .type, .runAppleScript, .scroll:
            return true
        case .openApp, .keyCombo, .wait:
            return false
        }
    }

    private func prependRefocusActionIfNeeded(
        _ correctiveActions: [AgentAction],
        originalPlan: ActionPlan,
        failureReason: String?
    ) -> [AgentAction] {
        guard let failureReason else { return correctiveActions }
        let normalizedReason = failureReason.lowercased()
        guard normalizedReason.contains("focused app unavailable") else {
            return correctiveActions
        }
        guard let openAction = originalPlan.actions.first(where: { $0.kind == .openApp }) else {
            return correctiveActions
        }
        if correctiveActions.first?.kind == .openApp {
            return correctiveActions
        }

        let refocus = AgentAction(
            id: "retry_refocus",
            kind: .openApp,
            target: openAction.target,
            text: nil,
            keyCombo: nil,
            appBundleId: openAction.appBundleId,
            timeoutMs: 1200,
            destructive: false,
            expectedOutcome: "Target app focused"
        )

        var merged = [refocus]
        merged.append(contentsOf: correctiveActions)
        return Array(merged.prefix(3))
    }

    private func normalizedAppToken(_ raw: String?) -> String {
        let lowered = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return "" }
        return lowered.replacingOccurrences(of: ".app", with: "")
    }

    private func activeAppSignature(from context: ScreenContext) -> String {
        let name = normalizedAppToken(context.app.name)
        let bundle = normalizedAppToken(context.app.bundleId)
        return [name, bundle].filter { !$0.isEmpty }.joined(separator: "/")
    }

    private struct VerificationSummary {
        var failed: Bool
        var reason: String?
        var observedState: String?
        var requiredTransition: String?
        var stateReason: String?
        var noProgressReason: String?
        var repeatedNoProgressBlocked: Bool
    }

    private func actionHint(_ action: AgentAction) -> String {
        switch action.kind {
        case .click, .doubleClick, .selectMenuItem, .openApp, .wait:
            return "\(action.kind.rawValue):\(action.target ?? "")"
        case .type, .runAppleScript:
            let value = action.text ?? ""
            return "\(action.kind.rawValue):\(value.prefix(80))"
        case .keyCombo:
            return "\(action.kind.rawValue):\(action.keyCombo ?? "")"
        case .scroll:
            return "\(action.kind.rawValue):\(action.target ?? "")"
        }
    }

    private func shouldPrompt(_ prompt: SafetyPrompt) -> Bool {
        switch prompt.approvalMode {
        case .oneTime, .alwaysAsk:
            return true
        case .perSession:
            return !sessionApprovals.contains(prompt.category)
        }
    }

    private func cleanupActiveWork(state: AppState, resetStatus: Bool) {
        canceled = true
        sttService.cancel()
        eventStreamTask?.cancel()
        eventStreamTask = nil
        executionTask?.cancel()
        executionTask = nil
        pendingPlan = nil
        pendingAllowCorrectiveRetry = true
        loopRuntime = nil
        state.safetyPrompts = []
        state.actionPlan = nil
        if resetStatus {
            state.state = .canceled
            state.statusText = "Canceled"
        }
    }

    private func submitTelemetry(
        state: AppState,
        stage: String,
        app: String? = nil,
        actionKind: String? = nil,
        status: String,
        latencyMs: Int? = nil,
        errorCode: String? = nil,
        cycleIndex: Int? = nil,
        replanCount: Int? = nil,
        terminationReason: String? = nil,
        loopState: String? = nil,
        stateTransition: String? = nil,
        actionFingerprint: String? = nil,
        fingerprintRepeatCount: Int? = nil,
        reasonNoProgress: String? = nil
    ) {
        let event = SessionTelemetryEvent(
            sessionId: state.sessionId,
            timestamp: timestampFormatter.string(from: Date()),
            stage: stage,
            app: app,
            actionKind: actionKind,
            status: status,
            latencyMs: latencyMs,
            errorCode: errorCode,
            cycleIndex: cycleIndex,
            replanCount: replanCount,
            terminationReason: terminationReason,
            loopState: loopState,
            stateTransition: stateTransition,
            actionFingerprint: actionFingerprint,
            fingerprintRepeatCount: fingerprintRepeatCount,
            reasonNoProgress: reasonNoProgress
        )
        Task {
            await plannerClient.telemetry(event: event)
        }
    }

    private func recordSafetyDecisions(state: AppState, decision: String) {
        let timestamp = timestampFormatter.string(from: Date())
        for prompt in state.safetyPrompts {
            state.safetyAuditTrail.append(
                SafetyDecisionRecord(
                    id: UUID().uuidString,
                    sessionId: state.sessionId,
                    category: prompt.category.rawValue,
                    decision: decision,
                    timestamp: timestamp,
                    approvalMode: prompt.approvalMode.rawValue
                )
            )
        }
    }
}
