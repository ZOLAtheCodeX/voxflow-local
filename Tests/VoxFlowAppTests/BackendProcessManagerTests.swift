import XCTest
@testable import VoxFlowApp

/// Records every system-touching call without performing any. Tests MUST use
/// this instead of the real runner: a manager built with the system runner
/// spawns a genuine uvicorn on port 8765 that outlives the test process —
/// the 2026-06-12 squatter incident was planted by this very test file.
final class BackendProcessRunnerFake: BackendProcessRunning, @unchecked Sendable {
    var ranProcesses: [Process] = []
    var terminations: [(pids: [pid_t], signal: Int32)] = []
    var listeners: [pid_t] = []
    var queriedPorts: [Int] = []
    var pidFile: pid_t?

    func run(_ process: Process) throws { ranProcesses.append(process) }
    func listeningPIDs(onPort port: Int) -> [pid_t] { queriedPorts.append(port); return listeners }
    func terminate(_ pids: [pid_t], signal: Int32) { terminations.append((pids, signal)) }
    func writePIDFile(_ pid: pid_t) { pidFile = pid }
    func readPIDFile() -> pid_t? { pidFile }
    func removePIDFile() { pidFile = nil }
}

final class BackendProcessManagerTests: XCTestCase {

    /// Wait for terminateForeignListenerAsync's serial-workQueue dispatch to land.
    private func waitForTermination(_ fake: BackendProcessRunnerFake, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while fake.terminations.isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Custom-port parity: stale/foreign-listener cleanup must target the SAME
    /// port the spawn + readiness use (resolved from VOXFLOW_BACKEND_URL), not a
    /// hardcoded 8765 — otherwise on a custom port it fails to reap the real
    /// stray AND could SIGTERM an unrelated process on 8765.
    func testForeignListenerTerminationHonorsCustomBackendPort() {
        setenv("VOXFLOW_BACKEND_URL", "http://127.0.0.1:9123", 1)
        defer { unsetenv("VOXFLOW_BACKEND_URL") }
        let fake = BackendProcessRunnerFake()
        fake.listeners = [4242]
        let manager = BackendProcessManager(runner: fake)

        manager.terminateForeignListenerAsync()
        waitForTermination(fake)

        XCTAssertEqual(fake.queriedPorts, [9123])
    }

    func testForeignListenerTerminationDefaultsTo8765WithoutOverride() {
        unsetenv("VOXFLOW_BACKEND_URL")
        let fake = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: fake)

        manager.terminateForeignListenerAsync()
        waitForTermination(fake)

        XCTAssertEqual(fake.queriedPorts, [8765])
    }

    func testCrashRestartRelaunchesThroughRunnerSeamOnly() {
        let runner = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: runner)
        let config = BackendLaunchConfiguration(
            sttBackend: "whisper",
            sttModel: "tiny",
            whisperModel: "tiny",
            translateModel: "none",
            translateBackend: "none",
            privateAPIBaseURL: "",
            privateAPIModel: "",
            privateAPIKey: "",
            openAIBaseURL: "",
            openAIAPIKey: "",
            openAISTTModel: "",
        )

        manager.handleUnexpectedExit(statusCode: 1, configuration: config)

        XCTAssertEqual(manager.crashRestartCount, 1)
        // The relaunch attempt went through the seam — and ONLY the seam.
        XCTAssertEqual(runner.ranProcesses.count, 1)
    }

    func testUnexpectedExitAutoRestartIncrementsCount() {
        let manager = BackendProcessManager(runner: BackendProcessRunnerFake())
        let config = BackendLaunchConfiguration(
            sttBackend: "whisper",
            sttModel: "tiny",
            whisperModel: "tiny",
            translateModel: "none",
            translateBackend: "none",
            privateAPIBaseURL: "",
            privateAPIModel: "",
            privateAPIKey: "",
            openAIBaseURL: "",
            openAIAPIKey: "",
            openAISTTModel: "",
        )

        XCTAssertEqual(manager.crashRestartCount, 0)

        // Trigger unexpected exit
        manager.handleUnexpectedExit(statusCode: 1, configuration: config)

        XCTAssertEqual(manager.crashRestartCount, 1)
    }

    func testUnexpectedExitStopsRestartingAfterMaxCrashes() {
        let manager = BackendProcessManager(runner: BackendProcessRunnerFake())
        let config = BackendLaunchConfiguration(
            sttBackend: "whisper",
            sttModel: "tiny",
            whisperModel: "tiny",
            translateModel: "none",
            translateBackend: "none",
            privateAPIBaseURL: "",
            privateAPIModel: "",
            privateAPIKey: "",
            openAIBaseURL: "",
            openAIAPIKey: "",
            openAISTTModel: "",
        )

        // Set crashRestartCount to max (3)
        manager.crashRestartCount = 3

        // Trigger unexpected exit
        manager.handleUnexpectedExit(statusCode: 1, configuration: config)

        // It should not increment further or restart
        XCTAssertEqual(manager.crashRestartCount, 3)
        XCTAssertEqual(manager.lastStartupFailureReason, "Backend crashed 3 times — restart manually in Settings")
    }
}

extension BackendProcessManagerTests {
    /// R4.7: stale-backend verdict. Absent stamps are stale by definition
    /// (pre-stamp backends); a manager-owned process is never foreign.
    func testForeignBackendVerdict() {
        XCTAssertTrue(BackendProcessManager.isForeignBackend(
            reportedStamp: "", expectedStamp: "me", managerOwnsProcess: false))
        XCTAssertTrue(BackendProcessManager.isForeignBackend(
            reportedStamp: nil, expectedStamp: "me", managerOwnsProcess: false))
        XCTAssertTrue(BackendProcessManager.isForeignBackend(
            reportedStamp: "other", expectedStamp: "me", managerOwnsProcess: false))
        XCTAssertFalse(BackendProcessManager.isForeignBackend(
            reportedStamp: "me", expectedStamp: "me", managerOwnsProcess: false))
        XCTAssertFalse(BackendProcessManager.isForeignBackend(
            reportedStamp: "other", expectedStamp: "me", managerOwnsProcess: true))
    }

    /// The default-init manager (used by the AppCoordinator singleton, which
    /// tests can reach via `.shared`) must resolve to the no-op runner under
    /// XCTest so no test can ever spawn, signal, or PID-file-touch the real
    /// system through the singleton's warmup paths.
    func testDefaultRunnerIsInertUnderXCTest() {
        XCTAssertTrue(BackendProcessManager.defaultRunner() is NoopBackendProcessRunner)
    }

    func testInstanceStampIsStablePerManager() {
        let manager = BackendProcessManager(runner: BackendProcessRunnerFake())
        XCTAssertFalse(manager.instanceStamp.isEmpty)
        XCTAssertEqual(manager.instanceStamp, manager.instanceStamp)
    }

    /// Launch-time identity probe: a listener we did not spawn, answering on
    /// our port without our stamp, is presumed stale and gets terminated —
    /// unless the dev escape hatch explicitly allows adopting it.
    func testIdleListenerTerminationVerdict() {
        // Nothing listening: nothing to do.
        XCTAssertFalse(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: false, reportedStamp: nil,
            expectedStamp: "me", adoptForeignOverride: false))
        // Our own stamp: healthy, leave it.
        XCTAssertFalse(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: "me",
            expectedStamp: "me", adoptForeignOverride: false))
        // Stamp-less (pre-stamp or orphaned) listener: stale, terminate.
        XCTAssertTrue(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: nil,
            expectedStamp: "me", adoptForeignOverride: false))
        XCTAssertTrue(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: "",
            expectedStamp: "me", adoptForeignOverride: false))
        // Another instance's stamp: stale orphan from a prior run, terminate.
        XCTAssertTrue(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: "other",
            expectedStamp: "me", adoptForeignOverride: false))
        // Escape hatch (VOXFLOW_ADOPT_FOREIGN_BACKEND=1): dev runs a manual
        // backend on purpose — never terminate, regardless of stamp.
        XCTAssertFalse(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: nil,
            expectedStamp: "me", adoptForeignOverride: true))
        XCTAssertFalse(BackendProcessManager.shouldTerminateIdleListener(
            listenerResponded: true, reportedStamp: "other",
            expectedStamp: "me", adoptForeignOverride: true))
    }

    private static func portParityTestConfig() -> BackendLaunchConfiguration {
        BackendLaunchConfiguration(
            sttBackend: "whisper",
            sttModel: "tiny",
            whisperModel: "tiny",
            translateModel: "none",
            translateBackend: "none",
            privateAPIBaseURL: "",
            privateAPIModel: "",
            privateAPIKey: "",
            openAIBaseURL: "",
            openAIAPIKey: "",
            openAISTTModel: "",
        )
    }

    /// Points VOXFLOW_BACKEND_PATH at a real (empty) entrypoint so the managed
    /// spawn reaches the runner seam deterministically, and sets the backend URL.
    private func withSpawnEnvironment(
        backendURL: String,
        _ body: (BackendProcessRunnerFake, BackendProcessManager) -> Void
    ) {
        let entry = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-server-\(UUID().uuidString).py")
        try? Data().write(to: entry)
        setenv("VOXFLOW_BACKEND_PATH", entry.path, 1)
        setenv("VOXFLOW_BACKEND_URL", backendURL, 1)
        defer {
            unsetenv("VOXFLOW_BACKEND_PATH")
            unsetenv("VOXFLOW_BACKEND_URL")
            try? FileManager.default.removeItem(at: entry)
        }
        let runner = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: runner)
        body(runner, manager)
    }

    func testSpawnEnvironmentCarriesResolvedCustomBackendPort() {
        withSpawnEnvironment(backendURL: "http://127.0.0.1:9000") { runner, manager in
            manager.startIfNeeded(configuration: Self.portParityTestConfig())
            XCTAssertEqual(runner.ranProcesses.count, 1, "managed spawn should launch through the runner seam")
            let env = runner.ranProcesses.first?.environment ?? [:]
            // The spawned uvicorn must bind the SAME host/port the client uses.
            XCTAssertEqual(env["VOXFLOW_BACKEND_HOST"], "127.0.0.1")
            XCTAssertEqual(env["VOXFLOW_BACKEND_PORT"], "9000")
        }
    }

    func testRefusesToSpawnManagedBackendOnNonLoopbackHost() {
        withSpawnEnvironment(backendURL: "http://192.168.1.50:8765") { runner, manager in
            manager.startIfNeeded(configuration: Self.portParityTestConfig())
            // The loopback guard must refuse BEFORE the runner is touched — the
            // entrypoint exists, so a missing guard WOULD have launched a process
            // bound to a routable interface.
            XCTAssertEqual(runner.ranProcesses.count, 0, "managed spawn must refuse a non-loopback host")
        }
    }

    func testRefusesToSpawnManagedBackendOverHTTPS() {
        withSpawnEnvironment(backendURL: "https://127.0.0.1:9000") { runner, manager in
            manager.startIfNeeded(configuration: Self.portParityTestConfig())
            // Managed spawn runs a PLAIN-HTTP uvicorn; an https URL (even on
            // loopback) would leave the client talking TLS to a plaintext socket.
            // Refuse it — https is valid only for a manually-run backend.
            XCTAssertEqual(runner.ranProcesses.count, 0, "managed spawn must refuse an https URL")
        }
    }
}
