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
    var commandLines: [pid_t: String] = [:]
    var queriedCommandLinePIDs: [pid_t] = []
    var pidFile: pid_t?
    var pidFileStamp: String?

    func run(_ process: Process) throws { ranProcesses.append(process) }
    func listeningPIDs(onPort port: Int) -> [pid_t] { queriedPorts.append(port); return listeners }
    func terminate(_ pids: [pid_t], signal: Int32) { terminations.append((pids, signal)) }
    func commandLine(forPID pid: pid_t) -> String? { queriedCommandLinePIDs.append(pid); return commandLines[pid] }
    func writePIDFile(_ pid: pid_t, stamp: String) { pidFile = pid; pidFileStamp = stamp }
    func readPIDFile() -> pid_t? { pidFile }
    func removePIDFile() { pidFile = nil; pidFileStamp = nil }
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

    private func waitUntil(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// PID-file reuse: a PID recorded in the file can be reused by an unrelated
    /// process after a crash. killStaleBackend must confirm identity before SIGTERM.
    func testKillStaleBackendRefusesReusedNonVoxFlowPID() {
        var killed: [pid_t] = []
        var removedFile = false
        BackendProcessManager.killStaleBackend(
            readRecord: { (7777, nil) },
            command: { _ in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
            terminate: { killed.append($0) },
            removePID: { removedFile = true },
            ownStamp: nil)
        XCTAssertEqual(killed, [], "a reused non-VoxFlow PID must never be killed")
        XCTAssertTrue(removedFile, "the stale PID file should still be cleared")
    }

    func testKillStaleBackendTerminatesConfirmedBackend() {
        var killed: [pid_t] = []
        BackendProcessManager.killStaleBackend(
            readRecord: { (8888, nil) },
            command: { _ in "/usr/bin/python3 /x/backend/app/server.py" },
            terminate: { killed.append($0) },
            removePID: {},
            ownStamp: nil)
        XCTAssertEqual(killed, [8888])
    }

    func testKillStaleBackendNoPIDFileIsNoOp() {
        var killed: [pid_t] = []
        BackendProcessManager.killStaleBackend(
            readRecord: { nil }, command: { _ in nil },
            terminate: { killed.append($0) }, removePID: {},
            ownStamp: nil)
        XCTAssertEqual(killed, [])
    }

    // MARK: - Stamp-bound PID file (own-session identity before SIGTERM)

    func testKillStaleBackendRefusesAnotherSessionsRecord() {
        // Concurrent sessions share one PID-file path. If the file records a
        // DIFFERENT session's stamp, that session's (possibly live, healthy)
        // backend is not ours to kill — refuse AND leave the file in place:
        // the record belongs to the other session.
        var killed: [pid_t] = []
        var removedFile = false
        BackendProcessManager.killStaleBackend(
            readRecord: { (8888, "STAMP-SESSION-B") },
            command: { _ in "/usr/bin/python3 /x/backend/app/server.py" },
            terminate: { killed.append($0) },
            removePID: { removedFile = true },
            ownStamp: "STAMP-SESSION-A")
        XCTAssertEqual(killed, [], "another session's backend must not be killed")
        XCTAssertFalse(removedFile, "the other session's PID record must be left in place")
    }

    func testKillStaleBackendKillsOwnRecordedChild() {
        var killed: [pid_t] = []
        var removedFile = false
        BackendProcessManager.killStaleBackend(
            readRecord: { (8888, "STAMP-MINE") },
            command: { _ in "/usr/bin/python3 /x/backend/app/server.py" },
            terminate: { killed.append($0) },
            removePID: { removedFile = true },
            ownStamp: "STAMP-MINE")
        XCTAssertEqual(killed, [8888])
        XCTAssertTrue(removedFile)
    }

    func testKillStaleBackendCrashRecoveryWithoutOwnStampUsesCmdlineGate() {
        // Idle-reap before this session ever spawned (ownStamp nil): the
        // record is a previous crashed session's leftover — exactly what the
        // reaper exists for. The cmdline gate alone decides, as before.
        var killed: [pid_t] = []
        BackendProcessManager.killStaleBackend(
            readRecord: { (8888, "STAMP-CRASHED-SESSION") },
            command: { _ in "/usr/bin/python3 /x/backend/app/server.py" },
            terminate: { killed.append($0) },
            removePID: {},
            ownStamp: nil)
        XCTAssertEqual(killed, [8888])
    }

    func testKillStaleBackendLegacyFileWithoutStampFallsBackToCmdlineGate() {
        var killed: [pid_t] = []
        BackendProcessManager.killStaleBackend(
            readRecord: { (8888, nil) },
            command: { _ in "/usr/bin/python3 /x/backend/app/server.py" },
            terminate: { killed.append($0) },
            removePID: {},
            ownStamp: "STAMP-MINE")
        XCTAssertEqual(killed, [8888])
    }

    func testPIDFileContentsRoundTripWithStamp() {
        let encoded = BackendProcessManager.encodePIDFileContents(pid: 1234, stamp: "ABC-123")
        let parsed = BackendProcessManager.parsePIDFileContents(encoded)
        XCTAssertEqual(parsed?.pid, 1234)
        XCTAssertEqual(parsed?.stamp, "ABC-123")
    }

    func testPIDFileParseAcceptsLegacyBarePID() {
        let parsed = BackendProcessManager.parsePIDFileContents("1234\n")
        XCTAssertEqual(parsed?.pid, 1234)
        XCTAssertNil(parsed?.stamp)
    }

    func testPIDFileParseRejectsGarbage() {
        XCTAssertNil(BackendProcessManager.parsePIDFileContents("not-a-pid"))
        XCTAssertNil(BackendProcessManager.parsePIDFileContents(""))
    }

    func testIsVoxFlowBackendCommand() {
        // Managed spawn: python running the bundled/repo server.py
        XCTAssertTrue(BackendProcessManager.isVoxFlowBackendCommand(
            "/usr/bin/python3 /Applications/VoxFlow.app/Contents/Resources/backend/app/server.py"))
        // Manually run (dev): uvicorn server:app
        XCTAssertTrue(BackendProcessManager.isVoxFlowBackendCommand(
            "/opt/homebrew/bin/uvicorn server:app --host 127.0.0.1 --port 8765"))
        // Unrelated processes / unknown
        XCTAssertFalse(BackendProcessManager.isVoxFlowBackendCommand(
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
        XCTAssertFalse(BackendProcessManager.isVoxFlowBackendCommand(nil))
        XCTAssertFalse(BackendProcessManager.isVoxFlowBackendCommand(""))
    }

    /// uvicorn writes ordinary access/startup lines to STDERR — logging every
    /// stderr chunk at error level made healthy requests look like backend
    /// failures in Console (one E entry per capture, session 29). Benign =
    /// every non-empty line carries an INFO/DEBUG level token; anything else
    /// (ERROR, tracebacks, unrecognized crash output) stays loud.
    func testStderrChunkClassificationKeepsUvicornNoiseQuiet() {
        // uvicorn access log line (the per-capture false positive)
        XCTAssertFalse(BackendProcessManager.stderrChunkIndicatesError(
            "INFO:     127.0.0.1:52713 - \"POST /v1/text/cleanup HTTP/1.1\" 200 OK"))
        // uvicorn startup banner
        XCTAssertFalse(BackendProcessManager.stderrChunkIndicatesError(
            "INFO:     Uvicorn running on http://127.0.0.1:8765 (Press CTRL+C to quit)"))
        // python logging via logging.getLogger("voxflow")
        XCTAssertFalse(BackendProcessManager.stderrChunkIndicatesError(
            "INFO:voxflow:polish served by ollama gemma4:e2b-mlx"))
        // multi-line chunk of benign lines (pipe reads coalesce)
        XCTAssertFalse(BackendProcessManager.stderrChunkIndicatesError(
            "INFO:     127.0.0.1:1 - \"GET /v1/health HTTP/1.1\" 200 OK\nINFO:voxflow:ready"))
    }

    func testStderrChunkClassificationStaysLoudForRealFailures() {
        XCTAssertTrue(BackendProcessManager.stderrChunkIndicatesError(
            "ERROR:    Exception in ASGI application"))
        XCTAssertTrue(BackendProcessManager.stderrChunkIndicatesError(
            "Traceback (most recent call last):"))
        // traceback continuation chunk with no level token — unknown stays loud
        XCTAssertTrue(BackendProcessManager.stderrChunkIndicatesError(
            "  File \"server.py\", line 10, in lifespan"))
        // a benign line mixed with a failure line — the failure wins
        XCTAssertTrue(BackendProcessManager.stderrChunkIndicatesError(
            "INFO:voxflow:starting\nRuntimeError: model not found"))
        // WARNING is not INFO/DEBUG: keep it visible
        XCTAssertTrue(BackendProcessManager.stderrChunkIndicatesError(
            "WARNING:  ASGI app factory detected"))
    }

    /// Identity check: a non-VoxFlow process holding the port must NOT be killed,
    /// even after a foreign verdict triggers terminateForeignListenerAsync.
    func testForeignListenerTerminationRefusesUnknownProcess() {
        let fake = BackendProcessRunnerFake()
        fake.listeners = [4242]
        fake.commandLines = [4242: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
        let manager = BackendProcessManager(runner: fake)

        manager.terminateForeignListenerAsync(port: 8765)
        waitUntil { fake.queriedCommandLinePIDs.contains(4242) }

        XCTAssertEqual(fake.terminations.flatMap(\.pids), [], "must not kill a non-VoxFlow process")
    }

    /// A confirmed VoxFlow backend on the port IS terminated.
    func testForeignListenerTerminationKillsConfirmedBackend() {
        let fake = BackendProcessRunnerFake()
        fake.listeners = [5555]
        fake.commandLines = [5555: "/usr/bin/python3 /x/backend/app/server.py"]
        let manager = BackendProcessManager(runner: fake)

        manager.terminateForeignListenerAsync(port: 8765)
        waitUntil { !fake.terminations.isEmpty }

        XCTAssertEqual(fake.terminations.flatMap(\.pids), [5555])
    }

    func testForeignListenerTerminationDefaultsTo8765WithoutOverride() {
        unsetenv("VOXFLOW_BACKEND_URL")
        let fake = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: fake)

        manager.terminateForeignListenerAsync()
        waitForTermination(fake)

        XCTAssertEqual(fake.queriedPorts, [8765])
    }

    /// Spin-wait for an async (backoff-scheduled) respawn to land.
    private func waitForRunCount(
        _ runner: BackendProcessRunnerFake, _ expected: Int, timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while runner.ranProcesses.count < expected, Date() < deadline {
            usleep(10_000)
        }
    }

    func testCrashRestartRelaunchesThroughRunnerSeamOnly() {
        let runner = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: runner)
        manager.crashRestartDelayOverride = 0
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
        waitForRunCount(runner, 1)
        XCTAssertEqual(runner.ranProcesses.count, 1)
    }

    /// Session 29 review: restarts were immediate — a fast-crashing child
    /// (broken venv, corrupted model dir) burned 4 back-to-back python+torch
    /// boots, hundreds of MB of page-ins each, exactly the IO-overload class
    /// implicated in capture losses. Backoff spaces them out.
    func testCrashRestartDelayScheduleBacksOff() {
        XCTAssertEqual(BackendProcessManager.crashRestartDelay(forAttempt: 1), 1.0)
        XCTAssertEqual(BackendProcessManager.crashRestartDelay(forAttempt: 2), 5.0)
        XCTAssertEqual(BackendProcessManager.crashRestartDelay(forAttempt: 3), 30.0)
        XCTAssertEqual(BackendProcessManager.crashRestartDelay(forAttempt: 7), 30.0)
    }

    /// The crash cap used to reset on EVERY warmup trigger (app activation,
    /// cockpit open, settings change), so "crashed 3 times — restart
    /// manually" was decorative: each activation re-armed a fresh 4-spawn
    /// storm. Warmup start attempts no longer reset the count; only the
    /// explicit restart path does.
    func testWarmupStartDoesNotResetCrashCap() {
        let runner = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: runner)
        manager.crashRestartCount = 3
        let config = BackendLaunchConfiguration(
            sttBackend: "whisper", sttModel: "tiny", whisperModel: "tiny",
            translateModel: "none", translateBackend: "none",
            privateAPIBaseURL: "", privateAPIModel: "", privateAPIKey: "",
            openAIBaseURL: "", openAIAPIKey: "", openAISTTModel: "")

        manager.startIfNeeded(configuration: config)
        XCTAssertEqual(manager.crashRestartCount, 3,
                       "warmup start must not re-arm the crash cap")

        manager.restart(configuration: config)
        XCTAssertEqual(manager.crashRestartCount, 0,
                       "the explicit restart path is the reset")
    }

    /// A crash mid-capture must not respawn python+torch WHILE the user is
    /// dictating on a 16 GB machine — the import storm competes with live
    /// audio IO (the active capture-loss theory). Respawn defers until the
    /// capture ends.
    func testRespawnDefersWhileCaptureActive() {
        let runner = BackendProcessRunnerFake()
        let manager = BackendProcessManager(runner: runner)
        manager.crashRestartDelayOverride = 0.02
        manager.setCaptureActive(true)
        let config = BackendLaunchConfiguration(
            sttBackend: "whisper", sttModel: "tiny", whisperModel: "tiny",
            translateModel: "none", translateBackend: "none",
            privateAPIBaseURL: "", privateAPIModel: "", privateAPIKey: "",
            openAIBaseURL: "", openAIAPIKey: "", openAISTTModel: "")

        manager.handleUnexpectedExit(statusCode: 1, configuration: config)

        usleep(150_000) // several defer cycles
        XCTAssertEqual(runner.ranProcesses.count, 0,
                       "respawn must wait out the in-flight capture")

        manager.setCaptureActive(false)
        waitForRunCount(runner, 1)
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
