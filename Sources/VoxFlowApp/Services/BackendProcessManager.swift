import Foundation
import os.log
import Darwin

private let log = Logger(subsystem: "local.voxflow.app", category: "BackendProcessManager")
private let pidFilePath = NSTemporaryDirectory() + "voxflow-backend.pid"

struct BackendLaunchConfiguration: Equatable, Sendable {
    let sttBackend: String
    let sttModel: String
    let whisperModel: String
    let translateModel: String
    let translateBackend: String
    let privateAPIBaseURL: String
    let privateAPIModel: String
    let privateAPIKey: String
    let openAIBaseURL: String
    let openAIAPIKey: String
    let openAISTTModel: String
    /// BYOM (R3.6): env-name -> API-key pairs resolved from the Keychain at
    /// launch time for providers declared in providers.json. Keys transit
    /// process environment only — never the config file.
    var providerKeys: [String: String] = [:]
}

/// Seam between the manager's lifecycle logic and the real system: child
/// process launch, port-listener queries, signal delivery, and the PID file
/// used to recognise our own strays. Production injects
/// ``SystemBackendProcessRunner``; tests MUST inject a recorder fake — a
/// unit test that constructs the real runner spawns a genuine uvicorn on
/// port 8765 that outlives the test runner (the 2026-06-12 squatter
/// incident was planted by exactly that, the same failure class as the
/// ghost-hello AX test).
protocol BackendProcessRunning: Sendable {
    func run(_ process: Process) throws
    func listeningPIDs(onPort port: Int) -> [pid_t]
    func terminate(_ pids: [pid_t], signal: Int32)
    func writePIDFile(_ pid: pid_t)
    func readPIDFile() -> pid_t?
    func removePIDFile()
}

struct SystemBackendProcessRunner: BackendProcessRunning {
    func run(_ process: Process) throws {
        try process.run()
    }

    func listeningPIDs(onPort port: Int) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]

        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Logger(subsystem: "local.voxflow.app", category: "BackendProcessRunner")
                .error("Failed to query port listeners on \(port): \(error.localizedDescription)")
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

    func terminate(_ pids: [pid_t], signal: Int32) {
        for pid in pids {
            _ = kill(pid, signal)
        }
    }

    func writePIDFile(_ pid: pid_t) { BackendProcessManager.writePIDFile(pid) }
    func readPIDFile() -> pid_t? { BackendProcessManager.readPIDFile() }
    func removePIDFile() { BackendProcessManager.removePIDFile() }
}

/// Inert runner selected automatically under XCTest (see
/// ``BackendProcessManager/defaultRunner()``): the AppCoordinator singleton
/// is reachable from tests, and its warmup paths must never spawn, signal,
/// or PID-file-touch the real system from a test process.
struct NoopBackendProcessRunner: BackendProcessRunning {
    func run(_ process: Process) throws {}
    func listeningPIDs(onPort port: Int) -> [pid_t] { [] }
    func terminate(_ pids: [pid_t], signal: Int32) {}
    func writePIDFile(_ pid: pid_t) {}
    func readPIDFile() -> pid_t? { nil }
    func removePIDFile() {}
}

final class BackendProcessManager: @unchecked Sendable {
    private static let defaultBackendPort = 8765

    /// R4.7: per-app-launch stamp passed to the backend as
    /// VOXFLOW_INSTANCE_STAMP and echoed on /v1/health + /v1/ready. A
    /// healthy port answered WITHOUT this stamp is a stale or foreign
    /// backend (the 2026-06-12 incident: a 2-week-old process served the
    /// app undetected) and gets replaced.
    let instanceStamp = UUID().uuidString

    /// Pure verdict: a responder is foreign when this manager does NOT own
    /// a running child and the echoed stamp differs (absent counts as
    /// differing — pre-stamp backends are by definition stale).
    static func isForeignBackend(reportedStamp: String?, expectedStamp: String, managerOwnsProcess: Bool) -> Bool {
        guard !managerOwnsProcess else { return false }
        return (reportedStamp ?? "") != expectedStamp
    }

    /// Launch-time identity probe verdict for the idle path, where the
    /// manager never owns the listener: anything answering on our port
    /// without this instance's stamp is presumed stale (a pre-stamp squatter
    /// or an orphan from a prior run). `adoptForeignOverride` is the dev
    /// escape hatch (`VOXFLOW_ADOPT_FOREIGN_BACKEND=1`) for intentionally
    /// pairing the app with a manually launched backend.
    static func shouldTerminateIdleListener(
        listenerResponded: Bool,
        reportedStamp: String?,
        expectedStamp: String,
        adoptForeignOverride: Bool
    ) -> Bool {
        guard listenerResponded, !adoptForeignOverride else { return false }
        return isForeignBackend(
            reportedStamp: reportedStamp,
            expectedStamp: expectedStamp,
            managerOwnsProcess: false
        )
    }

    /// Terminate whatever is listening on the backend port (SIGTERM). Only
    /// called after a foreign verdict; never signals our own process.
    func terminateForeignListenerAsync(port: Int = BackendProcessManager.defaultBackendPort) {
        workQueue.async { [runner] in
            let ownPid = ProcessInfo.processInfo.processIdentifier
            let pids = runner.listeningPIDs(onPort: port).filter { $0 != ownPid }
            runner.terminate(pids, signal: SIGTERM)
        }
    }
    private let workQueue = DispatchQueue(label: "local.voxflow.app.backend-process-manager")
    private let workQueueSpecificKey = DispatchSpecificKey<UInt8>()
    private let workQueueSpecificValue: UInt8 = 1

    private struct PythonInvocation {
        let executableURL: URL
        let arguments: [String]
    }

    private var process: Process?
    private var activeConfiguration: BackendLaunchConfiguration?
    private var pendingConfiguration: BackendLaunchConfiguration?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var _lastStartupFailureReason: String?
    private var lastSpawnedPID: pid_t?
    var crashRestartCount: Int = 0
    private var intentionalShutdown = false
    private static let maxCrashRestarts = 3

    var lastStartupFailureReason: String? {
        syncOnWorkQueue { _lastStartupFailureReason }
    }

    private let runner: BackendProcessRunning

    /// Real system runner in the app; inert runner under XCTest so the
    /// singleton-rooted object graph can never reach the system from tests.
    /// Tests that assert on runner interactions still inject their own fake.
    static func defaultRunner() -> BackendProcessRunning {
        NSClassFromString("XCTestCase") != nil
            ? NoopBackendProcessRunner()
            : SystemBackendProcessRunner()
    }

    init(runner: BackendProcessRunning = BackendProcessManager.defaultRunner()) {
        self.runner = runner
        workQueue.setSpecific(key: workQueueSpecificKey, value: workQueueSpecificValue)
    }

    var isRunning: Bool {
        syncOnWorkQueue {
            process?.isRunning == true
        }
    }

    func startIfNeeded(configuration: BackendLaunchConfiguration) {
        syncOnWorkQueue {
            crashRestartCount = 0
            startIfNeededOnWorkQueue(configuration: configuration)
        }
    }

    func startIfNeededAsync(configuration: BackendLaunchConfiguration) {
        workQueue.async { [weak self] in
            self?.crashRestartCount = 0
            self?.startIfNeededOnWorkQueue(configuration: configuration)
        }
    }

    func restart(configuration: BackendLaunchConfiguration) {
        syncOnWorkQueue {
            crashRestartCount = 0
            restartOnWorkQueue(configuration: configuration)
        }
    }

    func restartAsync(configuration: BackendLaunchConfiguration) {
        workQueue.async { [weak self] in
            self?.crashRestartCount = 0
            self?.restartOnWorkQueue(configuration: configuration)
        }
    }

    func stop() {
        syncOnWorkQueue {
            intentionalShutdown = true
            stopOnWorkQueue()
        }
    }

    func stopAsync() {
        workQueue.async { [weak self] in
            self?.intentionalShutdown = true
            self?.stopOnWorkQueue()
        }
    }

    private func restartOnWorkQueue(configuration: BackendLaunchConfiguration) {
        intentionalShutdown = true
        if process?.isRunning == true {
            pendingConfiguration = configuration
            stopOnWorkQueue()
        } else {
            startIfNeededOnWorkQueue(configuration: configuration)
        }
    }

    private func startIfNeededOnWorkQueue(configuration: BackendLaunchConfiguration) {
        intentionalShutdown = false
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
            intentionalShutdown = true
            pendingConfiguration = configuration
            stopOnWorkQueue()
            return
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
            try runner.run(task)
            process = task
            activeConfiguration = configuration
            lastSpawnedPID = task.processIdentifier
            _lastStartupFailureReason = nil
            log.info("Backend started (pid: \(task.processIdentifier))")
            runner.writePIDFile(task.processIdentifier)

            // Auto-restart on unexpected crash (non-zero exit), up to maxCrashRestarts.
            // Skip restart if the shutdown was intentional (stop/restart called).
            task.terminationHandler = { [weak self] terminatedProcess in
                let status = terminatedProcess.terminationStatus
                guard status != 0 else { return }
                guard let self else { return }
                self.workQueue.async { [weak self] in
                    guard let self else { return }
                    self.handleUnexpectedExit(statusCode: status, configuration: configuration)
                }
            }
        } catch {
            log.error("Failed to start backend: \(error.localizedDescription)")
            _lastStartupFailureReason = "Failed to start backend process: \(error.localizedDescription)"
            process = nil
            activeConfiguration = nil
            clearPipeHandlers()
        }
    }

    func handleUnexpectedExit(statusCode: Int32, configuration: BackendLaunchConfiguration) {
        guard !self.intentionalShutdown else {
            log.info("Backend exited after intentional shutdown; not auto-restarting")
            return
        }
        guard self.crashRestartCount < Self.maxCrashRestarts else {
            log.error("Backend crashed \(self.crashRestartCount) times; not restarting")
            self._lastStartupFailureReason = "Backend crashed \(Self.maxCrashRestarts) times — restart manually in Settings"
            return
        }
        self.crashRestartCount += 1
        log.warning("Backend crashed (exit \(statusCode)); auto-restart \(self.crashRestartCount)/\(Self.maxCrashRestarts)")
        self.process = nil
        self.clearPipeHandlers()
        self.startIfNeededOnWorkQueue(configuration: configuration)
    }

    private func stopOnWorkQueue() {
        guard let process, process.isRunning else {
            cleanupAfterTermination()
            return
        }

        let currentProcess = process
        process.terminationHandler = { [weak self] _ in
            self?.workQueue.async { [weak self] in
                self?.cleanupAfterTermination()
            }
        }

        process.terminate()

        // Schedule async fallbacks to ensure termination if terminate() hangs
        workQueue.asyncAfter(deadline: .now() + 5.0) { [weak self, weak currentProcess] in
            guard let self, let currentProcess, currentProcess.isRunning else { return }
            log.warning("Backend process did not terminate in 5 seconds; sending SIGINT")
            currentProcess.interrupt()

            self.workQueue.asyncAfter(deadline: .now() + 2.0) { [weak self, weak currentProcess] in
                guard let self, let currentProcess, currentProcess.isRunning else { return }
                log.error("Backend process did not respond to SIGINT; sending SIGKILL")
                _ = kill(currentProcess.processIdentifier, SIGKILL)

                // Force cleanup asynchronously on the work queue in case termination handler doesn't trigger
                self.workQueue.async { [weak self] in
                    self?.cleanupAfterTermination()
                }
            }
        }
    }

    private func cleanupAfterTermination() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        
        let hasActive = (process != nil || activeConfiguration != nil)
        if hasActive {
            self.process = nil
            self.activeConfiguration = nil
            self._lastStartupFailureReason = nil
            self.clearPipeHandlers()
            runner.removePIDFile()
            log.info("Backend process cleanup completed")
        }

        if let pending = pendingConfiguration {
            pendingConfiguration = nil
            intentionalShutdown = false
            startIfNeededOnWorkQueue(configuration: pending)
        }
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
        environment["VOXFLOW_INSTANCE_STAMP"] = instanceStamp
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["VOXFLOW_OFFLINE"] = "1"
        environment["VOXFLOW_STT_BACKEND"] = configuration.sttBackend
        environment["VOXFLOW_STT_MODEL"] = configuration.sttModel
        environment["VOXFLOW_WHISPER_MODEL"] = configuration.whisperModel
        environment["VOXFLOW_STT_ALLOW_FALLBACK"] = environment["VOXFLOW_STT_ALLOW_FALLBACK"] ?? "1"
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
        for (envName, key) in configuration.providerKeys where envName.hasPrefix("VOXFLOW_PROVIDER_KEY_") {
            environment[envName] = key
        }
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
        var pids = runner.listeningPIDs(onPort: port)
        pids.removeAll { $0 == getpid() }
        guard !pids.isEmpty else { return true }

        // Only kill PIDs that we previously spawned (in-memory or from PID file).
        // If an unknown process holds the port, log a warning and fail rather than force-killing.
        let stalePID = runner.readPIDFile()
        if let ownPID = lastSpawnedPID ?? stalePID {
            let ownPIDs = pids.filter { $0 == ownPID }
            let foreignPIDs = pids.filter { $0 != ownPID }

            if !foreignPIDs.isEmpty {
                log.warning("Port \(port) held by unknown process(es): \(foreignPIDs). Not killing.")
            }

            if !ownPIDs.isEmpty {
                log.warning("Port \(port) held by previous backend (pid \(ownPID)); terminating")
                runner.terminate(ownPIDs, signal: SIGTERM)
                usleep(400_000)

                // Check again — force-kill only our own PID if still alive
                let remaining = runner.listeningPIDs(onPort: port).filter { $0 == ownPID }
                if !remaining.isEmpty {
                    runner.terminate(remaining, signal: SIGKILL)
                    usleep(250_000)
                }
            }
        } else {
            log.warning("Port \(port) in use by \(pids) but no previously spawned PID to match")
        }

        pids = runner.listeningPIDs(onPort: port)
        pids.removeAll { $0 == getpid() }
        return pids.isEmpty
    }

    // MARK: - PID file persistence

    static func writePIDFile(_ pid: pid_t) {
        do {
            try "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
        } catch {
            log.warning("Failed to write PID file: \(error.localizedDescription)")
        }
    }

    static func removePIDFile() {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    static func readPIDFile() -> pid_t? {
        guard let contents = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else {
            return nil
        }
        // Check if process is still alive (signal 0 = existence check)
        guard kill(pid, 0) == 0 else {
            removePIDFile()
            return nil
        }
        return pid
    }

    /// Kill any stale backend from a previous app session. Called from atexit/terminate handlers
    /// as a last-resort cleanup when the normal stop() path didn't run.
    static func killStaleBackend() {
        guard let pid = readPIDFile() else { return }
        log.info("Killing stale backend (pid \(pid)) from PID file")
        kill(pid, SIGTERM)
        removePIDFile()
    }

}
