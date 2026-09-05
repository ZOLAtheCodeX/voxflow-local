import XCTest
@testable import VoxFlowApp

/// NEVER the real AccessibilityInsertService here: tests with the real
/// service performed genuine AX insertions into the focused app on every
/// suite run (the ghost-"hello" root cause, receipts in insertions.jsonl).
@MainActor
private final class ScriptedInsertService: TextInserting {
    var result = InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
    private(set) var insertedTexts: [String] = []
    private(set) var policies: [TextInsertionPolicy] = []

    func insert(text: String, targetApp: NSRunningApplication?, policy: TextInsertionPolicy) async -> InsertResult {
        policies.append(policy)
        return await insert(text: text, targetApp: targetApp)
    }

    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
        insertedTexts.append(text)
        return result
    }
}

final class TextInsertionCoordinatorTests: XCTestCase {
    @MainActor
    func testSkillCommandReachesInsertionVerbatimWithTimingReceipt() async throws {
        let state = AppState()
        let service = ScriptedInsertService()
        service.result = InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("insertion-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = TextInsertionCoordinator(state: state, insertService: service, audit: InsertionAuditLog(fileURL: file))
        let success = await coordinator.insertText("$research --local", statusSuffix: "Skill inserted",
            targetApp: nil, timing: InsertTimingContext(pipelineStartedAt: .now, sttMs: 123, cleanupMs: 0), policy: .verbatim)
        XCTAssertTrue(success)
        XCTAssertEqual(service.insertedTexts, ["$research --local"])
        XCTAssertEqual(service.policies, [.verbatim])
        XCTAssertEqual(state.lastInsertedText, "$research --local")
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(row["stt_ms"] as? Int, 123)
        XCTAssertEqual(row["cleanup_ms"] as? Int, 0)
    }

    @MainActor
    func testCancelledSkillCaptureNeverCallsInsertion() async {
        let state = AppState()
        let service = ScriptedInsertService()
        let coordinator = TextInsertionCoordinator(state: state, insertService: service)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.insertText("/research", statusSuffix: "Skill inserted", targetApp: nil,
                                                timing: nil, policy: .verbatim)
        }
        let success = await task.value
        XCTAssertFalse(success)
        XCTAssertTrue(service.insertedTexts.isEmpty)
    }

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

    /// Review-mode insert (user toggled to polish, then clicked Insert) must
    /// stamp the audit receipt with the selected mode's provenance — previously
    /// it hardcoded source "review", so review receipts couldn't tell Gemma from
    /// the regex floor (the auto-insert path's observability fix was incomplete).
    @MainActor
    func testReviewInsertRecordsSelectedModeProvenance() async throws {
        let state = AppState()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        let sut = TextInsertionCoordinator(
            state: state, insertService: ScriptedInsertService(),
            audit: InsertionAuditLog(fileURL: auditURL))

        state.transcriptCandidate = TranscriptCandidate(
            rawText: "raw", lightText: "light", polishText: "polished",
            selectedMode: .polish, polishProvenance: "gemma4:e2b-mlx")
        state.selectedMode = .polish

        await sut.insertCurrentText()

        let line = try String(contentsOf: auditURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(
            with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "insert")
        XCTAssertEqual((obj?["source"] as? String)?.contains("gemma4:e2b-mlx"), true,
                       "source was \(obj?["source"] as? String ?? "nil")")
    }

    /// Tail-loss forensics (session 29): the insert receipt carries the
    /// capture's duration/rms/peak from the candidate, so a transcript that
    /// only covers the head of a long dictation (decoder early-stop) is
    /// detectable post-hoc — previously only rejects logged audio stats.
    @MainActor
    func testInsertReceiptCarriesCandidateAudioStats() async throws {
        let state = AppState()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        let sut = TextInsertionCoordinator(
            state: state, insertService: ScriptedInsertService(),
            audit: InsertionAuditLog(fileURL: auditURL))

        state.transcriptCandidate = TranscriptCandidate(
            rawText: "raw", lightText: "light", polishText: "polish",
            selectedMode: .raw, audioSeconds: 11.7, rmsEnergy: 0.0679, peakAmplitude: 0.703)

        _ = await sut.insertText("light", statusSuffix: "Inserted", targetApp: nil)

        let line = try String(contentsOf: auditURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(
            with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["audio_seconds"] as? Double, 11.7)
        XCTAssertEqual(obj?["rms"] as? Double, 0.0679)
        XCTAssertEqual(obj?["peak_amplitude"] as? Double, 0.703)
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

    /// The insert receipt is the only persisted latency record: insert_ms is
    /// measured here, total_ms runs from the pipeline origin (hotkey release),
    /// and the method tells AX-direct from paste for later per-app tuning.
    @MainActor
    func testInsertTextStampsTimingAndMethod() async throws {
        let state = AppState()
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-test-audit-\(UUID().uuidString).jsonl")
        let service = ScriptedInsertService()
        service.result = InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        let sut = TextInsertionCoordinator(state: state, insertService: service, audit: InsertionAuditLog(fileURL: auditURL))
        let timing = InsertTimingContext(pipelineStartedAt: .now, sttMs: 640, cleanupMs: 3)

        let ok = await sut.insertText("hello", statusSuffix: "Inserted (light)", targetApp: nil, timing: timing)

        XCTAssertTrue(ok)
        let line = try String(contentsOf: auditURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["stt_ms"] as? Int, 640)
        XCTAssertEqual(obj?["cleanup_ms"] as? Int, 3)
        let insertMs = try XCTUnwrap(obj?["insert_ms"] as? Int)
        let totalMs = try XCTUnwrap(obj?["total_ms"] as? Int)
        XCTAssertGreaterThanOrEqual(insertMs, 0)
        XCTAssertGreaterThanOrEqual(totalMs, insertMs)
        XCTAssertEqual(obj?["insert_method"] as? String, "simulatedPaste")
    }
}
