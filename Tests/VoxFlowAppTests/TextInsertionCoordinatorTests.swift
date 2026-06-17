import XCTest
@testable import VoxFlowApp

/// NEVER the real AccessibilityInsertService here: tests with the real
/// service performed genuine AX insertions into the focused app on every
/// suite run (the ghost-"hello" root cause, receipts in insertions.jsonl).
@MainActor
private final class ScriptedInsertService: TextInserting {
    var result = InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
    private(set) var insertedTexts: [String] = []

    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
        insertedTexts.append(text)
        return result
    }
}

final class TextInsertionCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (TextInsertionCoordinator, AppState) {
        let state = AppState()
        let insertService = ScriptedInsertService()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        let sut = TextInsertionCoordinator(
            state: state,
            insertService: insertService,
            audit: InsertionAuditLog(fileURL: auditURL)
        )
        return (sut, state)
    }

    @MainActor
    func testInsertBlockedWhenPrivacyPreviewActive() async {
        let (sut, state) = makeSUT()
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "test", lightText: "test", polishText: "test", selectedMode: .raw
        )
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )

        await sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve privacy review before inserting")
        XCTAssertNotEqual(state.sessionState, .inserting)
    }

    @MainActor
    func testInsertBlockedWhenTranslationNotApproved() async {
        let (sut, state) = makeSUT()
        state.workflowMode = .translateEnToDe
        state.translationCandidate = TranslationCandidate(
            sourceEnglish: "hello", targetGerman: "hallo", approved: false
        )

        await sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve translation before inserting")
    }

    @MainActor
    func testInsertBlockedWhenMeetingNotApproved() async {
        let (sut, state) = makeSUT()
        state.workflowMode = .meeting
        state.meetingCandidate = MeetingCandidate(
            transcript: "test", summary: "sum", decisions: [], actionItems: [],
            followUps: [], speakerSegments: [], taskOwners: [],
            markdownExport: "", notionExport: "", approved: false
        )

        await sut.insertCurrentText()

        XCTAssertEqual(state.statusLine, "Approve meeting notes before inserting")
    }

    @MainActor
    func testInsertCurrentTextWritesAuditReceipt() async {
        let state = AppState()
        let insertService = ScriptedInsertService()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: auditURL) }
        let sut = TextInsertionCoordinator(
            state: state,
            insertService: insertService,
            audit: InsertionAuditLog(fileURL: auditURL)
        )
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "hello world", lightText: "Hello world.", polishText: "Hello, world.",
            selectedMode: .light, confidence: 0.91
        )
        state.selectedMode = .light

        await sut.insertCurrentText()

        // The review-mode insert must leave an audit receipt — the README and
        // InsertionAuditLog both promise EVERY insertion is logged, and this
        // path was the gap (only insertText recorded receipts).
        XCTAssertEqual(state.statusLine, "Inserted")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: auditURL.path),
            "insertCurrentText must write an audit receipt")
        let contents = (try? String(contentsOf: auditURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(contents.contains("\"event\":\"insert\""), "expected an insert receipt, got: \(contents)")
        XCTAssertTrue(contents.contains("Hello world."), "receipt should carry the inserted text")
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
    func testInsertEmptyTextIsNoOp() async {
        let (sut, state) = makeSUT()
        // No transcript, displayText is empty
        state.transcriptCandidate = nil

        await sut.insertCurrentText()

        XCTAssertNotEqual(state.sessionState, .inserting)
        XCTAssertEqual(state.successfulInsertCount, 0)
    }

    @MainActor
    func testInsertTextAcceptsTargetApp() async {
        let (sut, state) = makeSUT()
        state.transcriptCandidate = TranscriptCandidate(
            rawText: "hello", lightText: "hello", polishText: "hello", selectedMode: .raw
        )
        // Should compile and not crash — targetApp is optional
        _ = await sut.insertText("hello", statusSuffix: "test", targetApp: nil)
        // Insert may fail (no AX context in test), but it should not crash
        XCTAssertNotNil(state.lastInsertResult)
    }
}
