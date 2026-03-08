import Foundation

final class PythonSidecarManager {
    private var process: Process?
    private var startupTask: Task<Void, Never>?
    private let maxRestartAttempts = 3
    private var restartAttempts = 0
    private var isStopping = false
    private var isStarting = false
    private var launchAPIKey: String?

    func startIfNeeded(apiKey: String?) {
        launchAPIKey = apiKey
        if process?.isRunning == true || isStarting { return }
        isStarting = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            if await self.isHealthy() {
                self.isStarting = false
                self.restartAttempts = 0
                Logger.info("Using existing sidecar on 127.0.0.1:7789")
                return
            }
            self.restartAttempts = 0
            self.startProcess()
        }
    }

    func restart(apiKey: String?) {
        launchAPIKey = apiKey
        // If a startup health-check task is in flight, clear it so restart can proceed.
        startupTask?.cancel()
        startupTask = nil
        isStarting = false
        stop()
        startIfNeeded(apiKey: apiKey)
    }

    private func startProcess() {
        isStarting = true
        isStopping = false

        let p = Process()
        let launchMode = resolveLaunchMode()
        p.currentDirectoryURL = launchMode.workingDirectory
        p.executableURL = launchMode.executable
        p.arguments = launchMode.arguments
        p.environment = resolvedEnvironment(apiKey: launchAPIKey)

        let stdout = Pipe()
        let stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr
        attachLogReader(pipe: stdout, stream: "stdout")
        attachLogReader(pipe: stderr, stream: "stderr")
        p.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            Task { @MainActor in
                await self.handleTermination(terminated)
            }
        }

        do {
            try p.run()
            process = p
            Logger.info("Sidecar started")
            startupTask?.cancel()
            startupTask = Task { [weak self] in
                guard let self else { return }
                let healthy = await self.waitForHealth(timeoutSeconds: 8)
                await MainActor.run {
                    self.isStarting = false
                    if healthy {
                        self.restartAttempts = 0
                        Logger.info("Sidecar health check passed")
                    } else {
                        Logger.error("Sidecar health check failed")
                        self.restartIfNeeded(reason: "health_check_failed")
                    }
                }
            }
        } catch {
            isStarting = false
            Logger.error("Failed to start sidecar: \(error.localizedDescription)")
            restartIfNeeded(reason: "launch_failed")
        }
    }

    func stop() {
        isStopping = true
        isStarting = false
        startupTask?.cancel()
        startupTask = nil
        process?.terminate()
        process = nil
        Logger.info("Sidecar stopped")
    }

    private func resolveLaunchMode() -> LaunchMode {
        if let bundledExecutable = bundledSidecarExecutable() {
            let workingDirectory = bundledExecutable.deletingLastPathComponent()
            return LaunchMode(
                executable: bundledExecutable,
                arguments: ["--host", "127.0.0.1", "--port", "7789"],
                workingDirectory: workingDirectory
            )
        }

        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let agentDirectory = repoRoot.appendingPathComponent("agent")
        let pythonExecutable = resolveDevPythonExecutable(agentDirectory: agentDirectory)

        return LaunchMode(
            executable: pythonExecutable,
            arguments: ["-m", "uvicorn", "app.main:app", "--host", "127.0.0.1", "--port", "7789"],
            workingDirectory: agentDirectory
        )
    }

    private func resolveDevPythonExecutable(agentDirectory: URL) -> URL {
        let fileManager = FileManager.default
        let candidates = [
            agentDirectory.appendingPathComponent(".venv/bin/python3"),
            agentDirectory.appendingPathComponent(".venv313/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func bundledSidecarExecutable() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }

        let direct = resourceURL.appendingPathComponent("sidecar/sidecar_server")
        if FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }

        let nested = resourceURL.appendingPathComponent("sidecar/sidecar_server/sidecar_server")
        if FileManager.default.isExecutableFile(atPath: nested.path) {
            return nested
        }

        return nil
    }

    private func resolvedEnvironment(apiKey: String?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let key = apiKey, !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
        } else {
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
        }
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    private func restartIfNeeded(reason: String) {
        guard !isStopping else { return }
        guard restartAttempts < maxRestartAttempts else {
            Logger.error("Sidecar restart limit reached after reason=\(reason)")
            return
        }
        restartAttempts += 1
        Logger.error("Restarting sidecar (\(restartAttempts)/\(maxRestartAttempts)) reason=\(reason)")
        process?.terminate()
        process = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startProcess()
        }
    }

    private func handleTermination(_ terminated: Process) async {
        guard !isStopping else { return }
        let status = terminated.terminationStatus
        let reason = terminated.terminationReason == .exit ? "exit" : "uncaught_signal"
        Logger.error("Sidecar terminated reason=\(reason) status=\(status)")
        process = nil
        if await isHealthy() {
            isStarting = false
            restartAttempts = 0
            Logger.info("Existing sidecar remained healthy after termination; skipping restart")
            return
        }
        restartIfNeeded(reason: "terminated")
    }

    private func attachLogReader(pipe: Pipe, stream: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline)
            for line in lines where !line.isEmpty {
                Logger.info("[sidecar][\(stream)] \(line)")
            }
        }
    }

    private func waitForHealth(timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if await isHealthy() {
                return true
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:7789/health") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.7
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    deinit {
        stop()
    }
}

private struct LaunchMode {
    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
}
