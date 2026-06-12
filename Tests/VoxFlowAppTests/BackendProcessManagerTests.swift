import XCTest
@testable import VoxFlowApp

final class BackendProcessManagerTests: XCTestCase {

    func testUnexpectedExitAutoRestartIncrementsCount() {
        let manager = BackendProcessManager()
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
            openAITTSModel: "",
            openAITTSVoice: ""
        )

        XCTAssertEqual(manager.crashRestartCount, 0)

        // Trigger unexpected exit
        manager.handleUnexpectedExit(statusCode: 1, configuration: config)

        XCTAssertEqual(manager.crashRestartCount, 1)
    }

    func testUnexpectedExitStopsRestartingAfterMaxCrashes() {
        let manager = BackendProcessManager()
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
            openAITTSModel: "",
            openAITTSVoice: ""
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
}
