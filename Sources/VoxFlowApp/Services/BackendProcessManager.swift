import Foundation
import os.log
import Darwin

private let log = Logger(subsystem: "local.voxflow.app", category: "BackendProcessManager")

struct BackendLaunchConfiguration: Equatable {
    let sttBackend: String
    let sttModel: String
    let whisperModel: String
    let voxtralSafeModeEnabled: Bool
    let translateModel: String
    let translateBackend: String
    let privateAPIBaseURL: String
    let privateAPIModel: String
    let privateAPIKey: String
    let openAIBaseURL: String
    let openAIAPIKey: String
    let openAISTTModel: String
    let openAITTSModel: String
    let openAITTSVoice: String
}

final class BackendProcessManager: @unchecked Sendable {
    private static let defaultBackendPort = 8765
    private let workQueue = DispatchQueue(label: "local.voxflow.app.backend-process-manager")
    private let workQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let workQueueSpecificValue: UInt8 = 1

    private struct PythonInvocation {
        let executableURL: URL
        let arguments: [String]
    }

    private var process: Process?
    private var activeConfiguration: BackendLaunchConfiguration?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var _lastStartupFailureReason: String?

    var lastStartupFailureReason: String? {
        syncOnWorkQueue { _lastStartupFailureReason }
    }

    init() {
        workQueue.setSpecific(key: workQueueSpecificKey, value: workQueueSpecificValue)
    }

    var isRunning: Bool {
        syncOnWorkQueue {
            process?.isRunning == true
        }
    }

    func startIfNeeded(configuration: BackendLaunchConfiguration) {
        syncOnWorkQueue {
            startIfNeededOnWorkQueue(configuration: configuration)
        }
    }

    func startIfNeededAsync(configuration: BackendLaunchConfiguration) {
        workQueue.async { [weak self] in
            self?.startIfNeededOnWorkQueue(configuration: configuration)
        }
    }

    func restart(configuration: BackendLaunchConfiguration) {
        syncOnWorkQueue {
            restartOnWorkQueue(configuration: configuration)
        }
    }

    func restartAsync(configuration: BackendLaunchConfiguration) {
        workQueue.async { [weak self] in
            self?.restartOnWorkQueue(configuration: configuration)
        }
    }

    func stop() {
        syncOnWorkQueue {
            stopOnWorkQueue()
        }
    }

    func stopAsync() {
        workQueue.async { [weak self] in
            self?.stopOnWorkQueue()
        }
    }

    private func restartOnWorkQueue(configuration: BackendLaunchConfiguration) {
        stopOnWorkQueue()
        startIfNeededOnWorkQueue(configuration: configuration)
    }

    private func startIfNeededOnWorkQueue(configuration: BackendLaunchConfiguration) {
        _lastStartupFailureReason = nil

        if process?.isRunning != true {
            process = nil
            activeConfiguration = nil
            clearPipeHandlers()
        }

        if process?.isRunning == true {
            if activeConfiguration == configuration {
                return
            }
            stopOnWorkQueue()
        }

        let backendPort = resolveBackendPort()
        guard ensureBackendPortAvailable(backendPort) else {
            let issue = "Unable to free backend port \(backendPort)"
            log.error("\(issue)")
            _lastStartupFailureReason = issue
            process = nil
            activeConfiguration = nil
            clearPipeHandlers()
            return
        }

        let backendPath = resolveBackendPath()
        guard FileManager.default.fileExists(atPath: backendPath) else {
            let issue = "Backend entrypoint missing at \(backendPath)"
            log.error("\(issue)")
            _lastStartupFailureReason = issue
            return
        }

        let invocation = resolvePythonInvocation(forBackendPath: backendPath)
        let task = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        task.executableURL = invocation.executableURL
        task.arguments = invocation.arguments
        task.environment = mergedEnvironment(configuration: configuration)
        task.standardOutput = stdout
        task.standardError = stderr
        drainPipe(stdout, label: "stdout")
        drainPipe(stderr, label: "stderr")
        stdoutPipe = stdout
        stderrPipe = stderr

        do {
            try task.run()
            process = task
            activeConfiguration = configuration
            _lastStartupFailureReason = nil
            log.info("Backend started (pid: \(task.processIdentifier))")
        } catch {
            log.error("Failed to start backend: \(error.localizedDescription)")
            _lastStartupFailureReason = "Failed to start backend process: \(error.localizedDescription)"
            process = nil
            activeConfiguration = nil
            clearPipeHandlers()
        }
    }

    private func stopOnWorkQueue() {
        guard let process, process.isRunning else {
            self.process = nil
            activeConfiguration = nil
            _lastStartupFailureReason = nil
            clearPipeHandlers()
            return
        }

        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }

        if process.isRunning {
            process.interrupt()
        }

        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }

        self.process = nil
        activeConfiguration = nil
        _lastStartupFailureReason = nil
        clearPipeHandlers()
    }

    private func isOnWorkQueue() -> Bool {
        DispatchQueue.getSpecific(key: workQueueSpecificKey) == workQueueSpecificValue
    }

    private func syncOnWorkQueue<T>(_ operation: () -> T) -> T {
        if isOnWorkQueue() {
            return operation()
        }
        return workQueue.sync(execute: operation)
    }

    private func resolveBackendPath() -> String {
        if let explicit = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_PATH"], !explicit.isEmpty {
            return explicit
        }

        if let bundledBackend = Bundle.main.resourceURL?
            .appendingPathComponent("backend/app/server.py")
            .path,
           FileManager.default.fileExists(atPath: bundledBackend) {
            return bundledBackend
        }

        if let projectRoot = ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"], !projectRoot.isEmpty {
            let path = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent("backend/app/server.py")
                .path
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let currentDirectory = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: currentDirectory)
            .appendingPathComponent("backend/app/server.py")
            .path
    }

    private func resolvePythonInvocation(forBackendPath backendPath: String) -> PythonInvocation {
        if let explicitPython = ProcessInfo.processInfo.environment["VOXFLOW_PYTHON_PATH"], !explicitPython.isEmpty {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: explicitPython),
                arguments: [backendPath]
            )
        }

        if let bundledPython = Bundle.main.resourceURL?
            .appendingPathComponent("venv/bin/python3")
            .path,
           FileManager.default.fileExists(atPath: bundledPython) {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: bundledPython),
                arguments: [backendPath]
            )
        }

        if let projectRoot = ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"], !projectRoot.isEmpty {
            let projectPython = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent(".venv/bin/python3")
                .path
            if FileManager.default.fileExists(atPath: projectPython) {
                return PythonInvocation(
                    executableURL: URL(fileURLWithPath: projectPython),
                    arguments: [backendPath]
                )
            }
        }

        let currentDirectoryPython = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".venv/bin/python3")
            .path
        if FileManager.default.fileExists(atPath: currentDirectoryPython) {
            return PythonInvocation(
                executableURL: URL(fileURLWithPath: currentDirectoryPython),
                arguments: [backendPath]
            )
        }

        return PythonInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", backendPath]
        )
    }

    private func mergedEnvironment(configuration: BackendLaunchConfiguration) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": inherited["HOME"] ?? "",
            "TMPDIR": inherited["TMPDIR"] ?? "/tmp",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
        ]
        if let modelsDir = resolveModelsDirectory(inheritedEnvironment: inherited) {
            environment["VOXFLOW_MODELS_DIR"] = modelsDir
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONPYCACHEPREFIX"] = "/tmp/voxflow-pycache"
        environment["VOXFLOW_OFFLINE"] = "1"
        environment["VOXFLOW_STT_BACKEND"] = configuration.sttBackend
        environment["VOXFLOW_STT_MODEL"] = configuration.sttModel
        environment["VOXFLOW_WHISPER_MODEL"] = configuration.whisperModel
        environment["VOXFLOW_STT_ALLOW_FALLBACK"] = environment["VOXFLOW_STT_ALLOW_FALLBACK"] ?? "1"
        environment["VOXFLOW_VOXTRAL_SKIP_PRIMARY"] = configuration.voxtralSafeModeEnabled ? "1" : "0"
        environment["VOXFLOW_TRANSLATE_MODEL"] = configuration.translateModel
        environment["VOXFLOW_TRANSLATE_BACKEND"] = configuration.translateBackend
        environment["VOXFLOW_PRIVACY_POLICY_VERSION"] = "2026-02"
        environment["VOXFLOW_PRIVACY_REQUIRE_CONSENT"] = "1"
        environment["VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED"] = "1"
        environment["VOXFLOW_PRIVATE_API_BASE_URL"] = configuration.privateAPIBaseURL
        environment["VOXFLOW_PRIVATE_API_MODEL"] = configuration.privateAPIModel
        environment["VOXFLOW_PRIVATE_API_KEY"] = configuration.privateAPIKey
        environment["VOXFLOW_OPENAI_BASE_URL"] = configuration.openAIBaseURL
        environment["VOXFLOW_OPENAI_API_KEY"] = configuration.openAIAPIKey
        environment["VOXFLOW_OPENAI_STT_MODEL"] = configuration.openAISTTModel
        environment["VOXFLOW_OPENAI_TTS_MODEL"] = configuration.openAITTSModel
        environment["VOXFLOW_OPENAI_TTS_VOICE"] = configuration.openAITTSVoice
        return environment
    }

    private func resolveModelsDirectory(inheritedEnvironment: [String: String]) -> String? {
        if let explicit = inheritedEnvironment["VOXFLOW_MODELS_DIR"], !explicit.isEmpty {
            return explicit
        }

        if let bundledModels = Bundle.main.resourceURL?
            .appendingPathComponent("models")
            .path,
           FileManager.default.fileExists(atPath: bundledModels) {
            return bundledModels
        }

        if let projectRoot = inheritedEnvironment["VOXFLOW_PROJECT_ROOT"], !projectRoot.isEmpty {
            let projectModels = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent("models")
                .path
            if FileManager.default.fileExists(atPath: projectModels) {
                return projectModels
            }
        }

        let cwdModels = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("models")
            .path
        if FileManager.default.fileExists(atPath: cwdModels) {
            return cwdModels
        }

        return nil
    }

    private func drainPipe(_ pipe: Pipe, label: String) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !chunk.isEmpty else { return }
            if label == "stderr" {
                log.error("Backend \(label): \(chunk)")
            } else {
                log.debug("Backend \(label): \(chunk)")
            }
        }
    }

    private func clearPipeHandlers() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func resolveBackendPort() -> Int {
        let raw = ProcessInfo.processInfo.environment["VOXFLOW_BACKEND_URL"] ?? "http://127.0.0.1:\(Self.defaultBackendPort)"
        guard let url = URL(string: raw) else { return Self.defaultBackendPort }
        if let port = url.port {
            return port
        }
        if let scheme = url.scheme?.lowercased(), scheme == "https" {
            return 443
        }
        return 80
    }

    private func ensureBackendPortAvailable(_ port: Int) -> Bool {
        var pids = listeningPIDs(onPort: port)
        pids.removeAll { $0 == getpid() }
        guard !pids.isEmpty else { return true }

        log.warning("Port \(port) is in use; attempting recovery for backend startup")
        terminatePIDs(pids, signal: SIGTERM)
        usleep(400_000)

        pids = listeningPIDs(onPort: port)
        pids.removeAll { $0 == getpid() }
        if !pids.isEmpty {
            terminatePIDs(pids, signal: SIGKILL)
            usleep(250_000)
        }

        pids = listeningPIDs(onPort: port)
        pids.removeAll { $0 == getpid() }
        return pids.isEmpty
    }

    private func terminatePIDs(_ pids: [pid_t], signal: Int32) {
        for pid in pids {
            _ = kill(pid, signal)
        }
    }

    private func listeningPIDs(onPort port: Int) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            log.error("Failed to query port listeners on \(port): \(error.localizedDescription)")
            return []
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            return []
        }

        return raw
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

}
