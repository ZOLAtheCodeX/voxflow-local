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
    /// The full command line of a PID (for identity checks before terminating).
    /// nil when the process is gone or cannot be inspected.
    func commandLine(forPID pid: pid_t) -> String?
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

    func commandLine(forPID pid: pid_t) -> String? { BackendProcessManager.processCommandLine(pid) }

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
    func commandLine(forPID pid: pid_t) -> String? { nil }
    func writePIDFile(_ pid: pid_t) {}
    func readPIDFile() -> pid_t? { nil }
    func removePIDFile() {}
}

final class BackendProcessManager: @unchecked Sendable {
    // Resolve from the SAME endpoint the spawn + readiness use, so stale/foreign
    // listener cleanup honors a custom VOXFLOW_BACKEND_URL port. Was hardcoded
    // 8765: on a custom port the reaper queried/killed the wrong port (failing to
    // reap the real stray, and able to SIGTERM an unrelated process on 8765).
    private static var defaultBackendPort: Int { BackendEndpoint.resolved().port }

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
    /// True when a process command line identifies a VoxFlow backend — the
    /// managed spawn (`python …/backend/app/server.py`) or a manually-run
    /// `uvicorn server:app` (dev flow). Used to refuse terminating unrelated
    /// processes that merely hold the backend port or a reused PID.
    nonisolated static func isVoxFlowBackendCommand(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return false }
        return command.contains("backend/app/server.py") || command.contains("server:app")
    }

    func terminateForeignListenerAsync(port: Int = BackendProcessManager.defaultBackendPort) {
        workQueue.async { [runner, log] in
            let ownPid = ProcessInfo.processInfo.processIdentifier
            let candidates = runner.listeningPIDs(onPort: port).filter { $0 != ownPid }
            // Identity gate: a foreign verdict means "a VoxFlow backend we don't
            // own answered" — but the PID holding the port now could have changed
            // (TOCTOU) or be unrelated, so confirm each by command line before
            // SIGTERM. Unknown processes are refused and logged, never killed.
            var confirmed: [pid_t] = []
            var refused: [pid_t] = []
            for pid in candidates {
                if Self.isVoxFlowBackendCommand(runner.commandLine(forPID: pid)) {
                    confirmed.append(pid)
                } else {
                    refused.append(pid)
                }
            }
            if !refused.isEmpty {
                log.warning("Refusing to terminate non-VoxFlow process(es) on port \(port): \(refused)")
            }
            if !confirmed.isEmpty {
                runner.terminate(confirmed, signal: SIGTERM)
            }
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

        let endpoint = BackendEndpoint.resolved()
        // A managed spawn launches a plain-HTTP uvicorn bound to loopback.
        // Refuse anything else: a non-loopback host (LAN exposure) or an https
        // URL (the child has no TLS, so the client would talk TLS to a plaintext
        // socket). Either means "talk to a backend I run myself" — run it
        // manually (adopt-foreign) instead.
        guard endpoint.isManagedSpawnEligible else {
            let issue = "Refusing to spawn a managed backend for \(endpoint.url.absoluteString) — managed spawn supports only a plain-HTTP loopback URL; run the backend yourself for a custom host or TLS"
            log.error("\(issue)")
            _lastStartupFailureReason = issue
            process = nil
            activeConfiguration = nil
            clearPipeHandlers()
            return
        }
        let backendPort = endpoint.port
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
        // Tell the spawned uvicorn exactly where to bind so the client URL, the
        // stale-listener port checks, and the process all agree (loopback host
        // is guaranteed by the spawn-time isLoopback guard).
        let endpoint = BackendEndpoint.resolved()
        environment["VOXFLOW_BACKEND_HOST"] = endpoint.host
        environment["VOXFLOW_BACKEND_PORT"] = String(endpoint.port)
        environment["VOXFLOW_STT_BACKEND"] = configuration.sttBackend
        environment["VOXFLOW_STT_MODEL"] = configuration.sttModel
        environment["VOXFLOW_WHISPER_MODEL"] = configuration.whisperModel
        // Cloud STT fallback ships OFF: raw audio cannot be PII-redacted, so it
        // must never leave the Mac without explicit opt-in. Honor a shell-set
        // value for power users / dev; default off otherwise.
        environment["VOXFLOW_STT_ALLOW_FALLBACK"] = inherited["VOXFLOW_STT_ALLOW_FALLBACK"] ?? "0"
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
        BackendEndpoint.resolved().port
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
    /// The full command line of a PID via `ps` (nil if gone/uninspectable).
    /// Shared by the runner's `commandLine(forPID:)` and the static
    /// `killStaleBackend` identity check.
    static func processCommandLine(_ pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let cmd = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cmd?.isEmpty == false) ? cmd : nil
    }

    /// Reap the backend recorded in the PID file (used by the idle-reap path and
    /// the atexit fallback). Identity-gated: a PID can be REUSED by an unrelated
    /// process after a crash, so confirm it is actually a VoxFlow backend by
    /// command line before sending SIGTERM — otherwise just clear the stale file.
    /// Dependencies are injected (defaults wire the real system) so the policy is
    /// unit-testable without touching real processes. Static + synchronous so the
    /// C-level atexit handler can call it.
    static func killStaleBackend(
        readPID: () -> pid_t? = { readPIDFile() },
        command: (pid_t) -> String? = { processCommandLine($0) },
        terminate: (pid_t) -> Void = { _ = kill($0, SIGTERM) },
        removePID: () -> Void = { removePIDFile() }
    ) {
        guard let pid = readPID() else { return }
        guard isVoxFlowBackendCommand(command(pid)) else {
            log.warning("PID-file pid \(pid) is not a VoxFlow backend (gone or reused) — not killing; clearing stale PID file")
            removePID()
            return
        }
        log.info("Killing stale backend (pid \(pid)) from PID file")
        terminate(pid)
        removePID()
    }

}
