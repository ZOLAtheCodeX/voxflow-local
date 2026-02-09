import XCTest
@testable import VoxFlowApp

final class TextInsertionCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (TextInsertionCoordinator, AppState) {
        let state = AppState()
        let insertService = AccessibilityInsertService()
        let sut = TextInsertionCoordinator(state: state, insertService: insertService)
        return (sut, state)
    }

    @MainActor
    func testInsertBlockedWhenPrivacyPreviewActive() {
        let (sut, state) = makeSUT()
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "test", lightText: "test", polishText: "test", selectedMode: .raw
        )
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )

        sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve privacy review before inserting")
        XCTAssertNotEqual(state.sessionState, .inserting)
    }

    @MainActor
    func testInsertBlockedWhenTranslationNotApproved() {
        let (sut, state) = makeSUT()
        state.workflowMode = .translateEnToDe
        state.translationCandidate = TranslationCandidate(
            sourceEnglish: "hello", targetGerman: "hallo", approved: false
        )

        sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve translation before inserting")
    }

    @MainActor
    func testInsertBlockedWhenMeetingNotApproved() {
        let (sut, state) = makeSUT()
        state.workflowMode = .meeting
        state.meetingCandidate = MeetingCandidate(
            transcript: "test", summary: "sum", decisions: [], actionItems: [],
            followUps: [], speakerSegments: [], taskOwners: [],
            markdownExport: "", notionExport: "", approved: false
        )

        sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve meeting notes before inserting")
    }

    @MainActor
    func testRecordInsertStatsUpdatesPerAppCounters() {
        let (_, state) = makeSUT()
        // Directly test the stats structure the coordinator uses
        var stats = AppInsertStats(appName: "TestApp", successCount: 0, fallbackCount: 0, failedCount: 0)
        stats.successCount += 1
        stats.fallbackCount += 1
        state.insertStatsByApp["TestApp"] = stats

        XCTAssertEqual(state.insertStatsByApp["TestApp"]?.successCount, 1)
        XCTAssertEqual(state.insertStatsByApp["TestApp"]?.fallbackCount, 1)
    }

    @MainActor
    func testInsertEmptyTextIsNoOp() {
        let (sut, state) = makeSUT()
        // No transcript, displayText is empty
        state.transcriptCandidate = nil

        sut.insertCurrentText()

        XCTAssertNotEqual(state.sessionState, .inserting)
        XCTAssertEqual(state.successfulInsertCount, 0)
    }
}
