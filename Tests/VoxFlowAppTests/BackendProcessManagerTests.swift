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
    var pidFile: pid_t?

    func run(_ process: Process) throws { ranProcesses.append(process) }
    func listeningPIDs(onPort port: Int) -> [pid_t] { listeners }
    func terminate(_ pids: [pid_t], signal: Int32) { terminations.append((pids, signal)) }
    func writePIDFile(_ pid: pid_t) { pidFile = pid }
    func readPIDFile() -> pid_t? { pidFile }
    func removePIDFile() { pidFile = nil }
}

final class BackendProcessManagerTests: XCTestCase {

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

    func testInstanceStampIsStablePerManager() {
        let manager = BackendProcessManager()
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
}
