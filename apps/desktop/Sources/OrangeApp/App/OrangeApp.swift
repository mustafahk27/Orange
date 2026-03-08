import SwiftUI

@main
struct OrangeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @StateObject private var appState = AppState()
    @State private var showOnboarding = false
    @State private var showAPIKeySetup = false
    @State private var showDiagnostics = false
    @State private var attemptedProviderKeyResync = false
    @State private var permissionStatus = PermissionsManager.Status(
        accessibility: false,
        microphone: false,
        screenRecording: false
    )

    private let sessionManager: SessionManager
    private let sidecarManager = PythonSidecarManager()
    private let hotkeyManager = HotkeyManager()
    private let permissionsManager = PermissionsManager()
    private let credentialManager = CredentialManager()
    private let plannerClient: HTTPPlannerClient

    init() {
        let stt = AppleSpeechRecognizer()
        let context = LocalContextProvider()
        let planner = HTTPPlannerClient()
        let executor = ActionExecutor()
        let safety = DefaultSafetyPolicy()

        self.plannerClient = planner
        self.sessionManager = SessionManager(
            sttService: stt,
            contextProvider: context,
            plannerClient: planner,
            executionEngine: executor,
            safetyPolicy: safety
        )
    }

    var body: some Scene {
        WindowGroup("Orange") {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    // Hide scaffold only when no modal is being presented.
                    DispatchQueue.main.async {
                        hideScaffoldWindowIfNoModal()
                    }

                    refreshPermissionStatus()
                    sidecarManager.startIfNeeded(apiKey: credentialManager.loadAnthropicAPIKey())
                    refreshOnboardingGate()
                    Task { await refreshProviderHealth() }

                    OverlayWindow.shared.attach(rootView: overlayContent())
                    OverlayWindow.shared.show()

                    hotkeyManager.register(
                        onPress: { handleStart() },
                        onRelease: { handleStop() }
                    )

                    registerMenuBarObservers()
                }
                .onDisappear {
                    OverlayWindow.shared.hide()
                    sidecarManager.stop()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    refreshPermissionStatus()
                    refreshOnboardingGate()
                }
                .onChange(of: showAPIKeySetup) { _, isPresented in
                    if isPresented {
                        presentScaffoldWindowForModal()
                    } else {
                        hideScaffoldWindowIfNoModal()
                    }
                }
                .onChange(of: showOnboarding) { _, isPresented in
                    if isPresented {
                        presentScaffoldWindowForModal()
                    } else {
                        hideScaffoldWindowIfNoModal()
                    }
                }
                .onChange(of: showDiagnostics) { _, isPresented in
                    if isPresented {
                        presentScaffoldWindowForModal()
                    } else {
                        hideScaffoldWindowIfNoModal()
                    }
                }
                .onChange(of: appState.onboardingGate) { _, newValue in
                    if newValue == .needsAPIKey {
                        showAPIKeySetup = true
                    }
                }
                .sheet(isPresented: $showAPIKeySetup) {
                    APIKeySetupView(
                        existingKeyPresent: credentialManager.hasAnthropicAPIKey(),
                        onValidate: { key in
                            await validateAPIKey(key)
                        },
                        onSave: { key in
                            saveAPIKey(key)
                        }
                    )
                    .interactiveDismissDisabled(appState.onboardingGate == .needsAPIKey)
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(
                        status: permissionStatus,
                        onRequestAccessibility: {
                            _ = permissionsManager.promptAccessibilityPermission()
                            permissionsManager.openSettingsAccessibility()
                            startPermissionRefreshPolling()
                        },
                        onRequestMicrophone: {
                            Task {
                                _ = await permissionsManager.requestMicrophonePermission()
                                permissionsManager.openSettingsMicrophone()
                                await MainActor.run {
                                    refreshPermissionStatus()
                                    refreshOnboardingGate()
                                }
                            }
                        },
                        onRequestScreenRecording: {
                            _ = permissionsManager.requestScreenRecordingPermission()
                            permissionsManager.openSettingsScreenRecording()
                            startPermissionRefreshPolling()
                        },
                        onRefresh: {
                            refreshPermissionStatus()
                            refreshOnboardingGate()
                        }
                    )
                    .interactiveDismissDisabled(appState.onboardingGate == .needsPermissions)
                }
                .alert("Diagnostics", isPresented: $showDiagnostics) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(appState.diagnosticsText)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Orange") {
                Button("API Key Setup") {
                    showAPIKeySetup = true
                }

                Button("Reset API Key") {
                    resetAPIKey()
                }

                Button("Diagnostics") {
                    Task {
                        await loadDiagnostics()
                        showDiagnostics = true
                    }
                }

                Divider()

                Button("Permissions Setup") {
                    refreshPermissionStatus()
                    refreshOnboardingGate()
                    showOnboarding = true
                }
            }
        }
    }

    private func handleStart() {
        refreshOnboardingGate()
        guard appState.onboardingGate == .ready else {
            switch appState.onboardingGate {
            case .needsAPIKey:
                appState.statusText = "Enter Anthropic API key"
                showAPIKeySetup = true
            case .needsPermissions:
                appState.statusText = "Grant required permissions"
                showOnboarding = true
            case .ready:
                break
            }
            return
        }

        if !appState.sidecarHealthy {
            Task {
                await refreshProviderHealth()
            }
            appState.statusText = "Starting sidecar..."
            return
        }

        sessionManager.beginRecording(state: appState)
    }

    private func handleStop() {
        guard appState.state == .listening else { return }
        guard appState.isReadyForCommands else {
            appState.statusText = "Setup incomplete"
            return
        }
        Task {
            await sessionManager.stopRecordingAndPlan(state: appState)
        }
    }

    private func refreshPermissionStatus() {
        permissionStatus = permissionsManager.currentStatus()
    }

    private func refreshOnboardingGate() {
        if !credentialManager.hasAnthropicAPIKey() {
            appState.onboardingGate = .needsAPIKey
            showAPIKeySetup = true
            showOnboarding = false
            return
        }

        if !permissionStatus.allGranted {
            appState.onboardingGate = .needsPermissions
            showOnboarding = true
            showAPIKeySetup = false
            return
        }

        appState.onboardingGate = .ready
        showAPIKeySetup = false
        showOnboarding = false
    }

    private func startPermissionRefreshPolling() {
        Task {
            for _ in 0..<45 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let status = permissionsManager.currentStatus()
                await MainActor.run {
                    permissionStatus = status
                    refreshOnboardingGate()
                }
                if status.allGranted {
                    break
                }
            }
        }
    }

    private func validateAPIKey(_ key: String) async -> ProviderValidateResponse {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProviderValidateResponse(
                provider: "anthropic",
                valid: false,
                reason: "API key is empty.",
                accountHint: nil
            )
        }

        do {
            return try await plannerClient.validateProvider(
                request: ProviderValidateRequest(
                    provider: "anthropic",
                    apiKey: trimmed
                )
            )
        } catch {
            let reason: String
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut:
                    reason = "Validation timed out. You can still save the key and it will be used when the app is ready."
                case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                    reason = "Could not reach the validation service. You can still save the key and it will be validated when the app starts."
                case .cancelled:
                    reason = "Validation was cancelled."
                default:
                    reason = "Network error during validation. You can still save the key."
                }
            } else {
                reason = "Validation error: \(error.localizedDescription)"
            }
            return ProviderValidateResponse(
                provider: "anthropic",
                valid: false,
                reason: reason,
                accountHint: nil
            )
        }
    }

    private func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard credentialManager.saveAnthropicAPIKey(trimmed) else {
            appState.statusText = "Failed to save API key to Keychain"
            Logger.error("saveAPIKey: Keychain write failed for provided key")
            return
        }

        // Read-back verification: confirm the key actually persisted before proceeding.
        guard let readBack = credentialManager.loadAnthropicAPIKey(), readBack == trimmed else {
            appState.statusText = "API key could not be read back from Keychain — please try again"
            Logger.error("saveAPIKey: Keychain read-back mismatch after write")
            return
        }

        sidecarManager.restart(apiKey: trimmed)
        appState.statusText = "API key saved"

        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            await ensureProviderKeyConfigured(expectedKey: trimmed)
            await refreshProviderHealth()
            refreshPermissionStatus()
            refreshOnboardingGate()
        }
    }

    private func resetAPIKey() {
        credentialManager.resetAnthropicAPIKey()
        sidecarManager.restart(apiKey: nil)
        attemptedProviderKeyResync = false
        appState.sidecarHealthy = false
        appState.statusText = "API key removed"
        refreshOnboardingGate()
    }

    private func refreshProviderHealth() async {
        do {
            let status = try await plannerClient.providerStatus()
            if !status.keyConfigured,
               let savedKey = credentialManager.loadAnthropicAPIKey(),
               !savedKey.isEmpty,
               !attemptedProviderKeyResync
            {
                attemptedProviderKeyResync = true
                sidecarManager.restart(apiKey: savedKey)
                try? await Task.sleep(nanoseconds: 600_000_000)
                await refreshProviderHealth()
                return
            }
            await MainActor.run {
                appState.sidecarHealthy = status.health
            }
        } catch {
            await MainActor.run {
                appState.sidecarHealthy = false
            }
        }
    }

    private func ensureProviderKeyConfigured(expectedKey: String) async {
        for _ in 0..<3 {
            do {
                let status = try await plannerClient.providerStatus()
                if status.keyConfigured {
                    attemptedProviderKeyResync = false
                    return
                }
            } catch {
                // Fall through to restart-and-retry.
            }
            sidecarManager.restart(apiKey: expectedKey)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        await MainActor.run {
            appState.statusText = "Key saved, but sidecar did not pick it up yet"
        }
    }

    private func loadDiagnostics() async {
        let permission = permissionsManager.currentStatus()
        let keyHint: String
        if let key = credentialManager.loadAnthropicAPIKey() {
            let tail = key.count >= 4 ? String(key.suffix(4)) : "****"
            keyHint = "present (…\(tail))"
        } else {
            keyHint = "missing"
        }
        let providerLine: String
        do {
            let providerStatus = try await plannerClient.providerStatus()
            providerLine = "Provider: \(providerStatus.provider), keyConfigured=\(providerStatus.keyConfigured), health=\(providerStatus.health), models=\(providerStatus.modelSimple)/\(providerStatus.modelComplex)"
        } catch {
            providerLine = "Provider: unavailable (\(error.localizedDescription))"
        }

        appState.diagnosticsText = [
            providerLine,
            "Keychain key: \(keyHint)",
            "Gate: \(appState.onboardingGate.rawValue)",
            "Permissions: accessibility=\(permission.accessibility), mic=\(permission.microphone), screen=\(permission.screenRecording)",
            "Sidecar healthy: \(appState.sidecarHealthy)",
            "",
            "Recent logs:",
            Logger.recentMessages().joined(separator: "\n")
        ].joined(separator: "\n")
    }

    private func registerMenuBarObservers() {
        NotificationCenter.default.addObserver(
            forName: .orangeShowOverlay, object: nil, queue: .main
        ) { [self] _ in
            Task { @MainActor in
                OverlayWindow.shared.show()
                appState.overlayExpanded = true
                OverlayWindow.shared.setMode(.expanded)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .orangeShowAPIKeySetup, object: nil, queue: .main
        ) { _ in
            showAPIKeySetup = true
        }
        NotificationCenter.default.addObserver(
            forName: .orangeShowPermissions, object: nil, queue: .main
        ) { _ in
            refreshPermissionStatus()
            showOnboarding = true
        }
        NotificationCenter.default.addObserver(
            forName: .orangeShowDiagnostics, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                await loadDiagnostics()
                showDiagnostics = true
            }
        }
    }

    @ViewBuilder
    private func overlayContent() -> some View {
        OverlayView(
            appState: appState,
            onStart: {
                handleStart()
            },
            onStop: {
                handleStop()
            },
            onConfirm: {
                Task { await sessionManager.confirmAndExecute(state: appState) }
            },
            onCancel: {
                sessionManager.cancel(state: appState)
            },
            onDiagnostics: {
                Task {
                    await loadDiagnostics()
                    showDiagnostics = true
                }
            }
        )
    }

    @MainActor
    private func scaffoldWindow() -> NSWindow? {
        NSApplication.shared.windows.first { $0.title == "Orange" && !($0 is NSPanel) }
    }

    @MainActor
    private func presentScaffoldWindowForModal() {
        guard let window = scaffoldWindow() else { return }
        if let screen = window.screen ?? NSScreen.main {
            let width: CGFloat = 560
            let height: CGFloat = 380
            let x = screen.visibleFrame.midX - (width / 2)
            let y = screen.visibleFrame.midY - (height / 2)
            window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        }
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func hideScaffoldWindowIfNoModal() {
        guard !showAPIKeySetup, !showOnboarding, !showDiagnostics else { return }
        scaffoldWindow()?.orderOut(nil)
    }
}
