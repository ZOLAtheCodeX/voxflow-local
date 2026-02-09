import XCTest
@testable import VoxFlowApp

final class AppModelTests: XCTestCase {

    // MARK: - Enum displayName uniqueness

    func testCleanupModeDisplayNamesUnique() {
        let labels = Set(CleanupMode.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, CleanupMode.allCases.count)
    }

    func testWorkflowModeDisplayNamesUnique() {
        let labels = Set(WorkflowMode.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, WorkflowMode.allCases.count)
    }

    func testToneStyleDisplayNamesUnique() {
        let labels = Set(ToneStyle.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, ToneStyle.allCases.count)
    }

    func testProviderModeDisplayNamesUnique() {
        let labels = Set(ProviderMode.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, ProviderMode.allCases.count)
    }

    func testSTTBackendDisplayNamesUnique() {
        let labels = Set(STTBackend.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, STTBackend.allCases.count)
    }

    // MARK: - TranscriptCandidate.text(for:)

    func testTranscriptCandidateTextForRaw() {
        let candidate = TranscriptCandidate(
            rawText: "raw version", lightText: "light version",
            polishText: "polish version", selectedMode: .raw
        )
        XCTAssertEqual(candidate.text(for: .raw), "raw version")
    }

    func testTranscriptCandidateTextForLight() {
        let candidate = TranscriptCandidate(
            rawText: "raw", lightText: "light", polishText: "polish", selectedMode: .light
        )
        XCTAssertEqual(candidate.text(for: .light), "light")
    }

    func testTranscriptCandidateTextForPolish() {
        let candidate = TranscriptCandidate(
            rawText: "raw", lightText: "light", polishText: "polish", selectedMode: .polish
        )
        XCTAssertEqual(candidate.text(for: .polish), "polish")
    }

    // MARK: - AppInsertStats.successRate

    func testSuccessRateZeroAttempts() {
        let stats = AppInsertStats(appName: "TestApp", successCount: 0, fallbackCount: 0, failedCount: 0)
        XCTAssertEqual(stats.successRate, 0)
    }

    func testSuccessRate100Percent() {
        let stats = AppInsertStats(appName: "TestApp", successCount: 10, fallbackCount: 2, failedCount: 0)
        XCTAssertEqual(stats.successRate, 1.0)
    }

    func testSuccessRate50Percent() {
        let stats = AppInsertStats(appName: "TestApp", successCount: 5, fallbackCount: 0, failedCount: 5)
        XCTAssertEqual(stats.successRate, 0.5)
    }

    // MARK: - AppInsertStats.totalAttempts

    func testTotalAttemptsSumsSuccessAndFailed() {
        let stats = AppInsertStats(appName: "TestApp", successCount: 3, fallbackCount: 7, failedCount: 2)
        // totalAttempts = successCount + failedCount (NOT fallbackCount)
        XCTAssertEqual(stats.totalAttempts, 5)
    }

    // MARK: - TranslationBenchmarkHistoryStats

    func testAverageMedianLatencyNormal() {
        let stats = TranslationBenchmarkHistoryStats(
            profile: .translateGemma4B, benchmarkRuns: 3, successfulRuns: 3,
            placeholderRuns: 0, totalMedianLatencyMs: 3000, totalP95LatencyMs: 6000,
            lastMedianLatencyMs: 1000, lastP95LatencyMs: 2000
        )
        XCTAssertEqual(stats.averageMedianLatencyMs, 1000)  // 3000 / 3
    }

    func testAverageMedianLatencyZeroDivision() {
        let stats = TranslationBenchmarkHistoryStats(
            profile: .translateGemma4B, benchmarkRuns: 0, successfulRuns: 0,
            placeholderRuns: 0, totalMedianLatencyMs: 0, totalP95LatencyMs: 0,
            lastMedianLatencyMs: nil, lastP95LatencyMs: nil
        )
        XCTAssertEqual(stats.averageMedianLatencyMs, 0)
    }

    func testRecommendationScoreFormula() {
        let stats = TranslationBenchmarkHistoryStats(
            profile: .translateGemma4B, benchmarkRuns: 2, successfulRuns: 2,
            placeholderRuns: 1, totalMedianLatencyMs: 2000, totalP95LatencyMs: 4000,
            lastMedianLatencyMs: nil, lastP95LatencyMs: nil
        )
        // avgMedian = 2000/2 = 1000
        // avgP95 = 4000/2 = 2000
        // score = 1000 + (2000/4) + (1 * 2000) = 1000 + 500 + 2000 = 3500
        XCTAssertEqual(stats.recommendationScore, 3500)
    }

    func testRecommendationScoreZeroRunsReturnsIntMax() {
        let stats = TranslationBenchmarkHistoryStats(
            profile: .marianFallback, benchmarkRuns: 0, successfulRuns: 0,
            placeholderRuns: 0, totalMedianLatencyMs: 0, totalP95LatencyMs: 0,
            lastMedianLatencyMs: nil, lastP95LatencyMs: nil
        )
        XCTAssertEqual(stats.recommendationScore, Int.max)
    }

    // MARK: - TranslationProfile.runtimeHint

    func testGemma4BHighMemory() {
        let hint = TranslationProfile.translateGemma4B.runtimeHint(forHostMemoryGB: 16)
        XCTAssertEqual(hint.suitability, .recommended)
    }

    func testGemma4BMediumMemory() {
        let hint = TranslationProfile.translateGemma4B.runtimeHint(forHostMemoryGB: 12)
        XCTAssertEqual(hint.suitability, .caution)
    }

    func testGemma4BLowMemory() {
        let hint = TranslationProfile.translateGemma4B.runtimeHint(forHostMemoryGB: 8)
        XCTAssertEqual(hint.suitability, .heavy)
    }

    func testGemma12BHighMemory() {
        let hint = TranslationProfile.translateGemma12B.runtimeHint(forHostMemoryGB: 32)
        XCTAssertEqual(hint.suitability, .recommended)
    }

    func testGemma12BMediumMemory() {
        let hint = TranslationProfile.translateGemma12B.runtimeHint(forHostMemoryGB: 24)
        XCTAssertEqual(hint.suitability, .caution)
    }

    func testGemma12BLowMemory() {
        let hint = TranslationProfile.translateGemma12B.runtimeHint(forHostMemoryGB: 16)
        XCTAssertEqual(hint.suitability, .heavy)
    }

    func testMarianHighMemory() {
        let hint = TranslationProfile.marianFallback.runtimeHint(forHostMemoryGB: 8)
        XCTAssertEqual(hint.suitability, .recommended)
    }

    func testMarianMediumMemory() {
        let hint = TranslationProfile.marianFallback.runtimeHint(forHostMemoryGB: 16)
        XCTAssertEqual(hint.suitability, .recommended)
    }

    func testMarianLowMemory() {
        let hint = TranslationProfile.marianFallback.runtimeHint(forHostMemoryGB: 4)
        XCTAssertEqual(hint.suitability, .caution)
    }

    // MARK: - MeetingCandidate.formattedNotes

    func testFormattedNotesEmptyArrays() {
        let candidate = MeetingCandidate(
            transcript: "test", summary: "Summary text",
            decisions: [], actionItems: [], followUps: [],
            speakerSegments: [], taskOwners: [],
            markdownExport: "", notionExport: "", approved: false
        )
        let notes = candidate.formattedNotes
        XCTAssertTrue(notes.contains("- None captured"))
        XCTAssertTrue(notes.contains("- None inferred"))
    }

    func testFormattedNotesWithContent() {
        let candidate = MeetingCandidate(
            transcript: "test", summary: "Summary text",
            decisions: ["Decision A"], actionItems: ["Action B"],
            followUps: ["Follow C"],
            speakerSegments: [MeetingSpeakerSegment(speaker: "Alice", text: "Hello", utteranceCount: 2)],
            taskOwners: [MeetingTaskOwner(task: "Do X", owner: "Bob", confidence: 0.9)],
            markdownExport: "", notionExport: "", approved: false
        )
        let notes = candidate.formattedNotes
        XCTAssertTrue(notes.contains("Decision A"))
        XCTAssertTrue(notes.contains("Action B"))
        XCTAssertTrue(notes.contains("Follow C"))
        XCTAssertTrue(notes.contains("Alice"))
        XCTAssertTrue(notes.contains("Bob"))
        XCTAssertTrue(notes.contains("90%"))
    }

    func testMarkdownTemplateUsesExportWhenPresent() {
        let candidate = MeetingCandidate(
            transcript: "test", summary: "Summary",
            decisions: [], actionItems: [], followUps: [],
            speakerSegments: [], taskOwners: [],
            markdownExport: "# Custom Export", notionExport: "", approved: false
        )
        XCTAssertEqual(candidate.markdownTemplate, "# Custom Export")
    }

    func testMarkdownTemplateFallsBackToFormattedNotes() {
        let candidate = MeetingCandidate(
            transcript: "test", summary: "Summary",
            decisions: [], actionItems: [], followUps: [],
            speakerSegments: [], taskOwners: [],
            markdownExport: "", notionExport: "", approved: false
        )
        XCTAssertEqual(candidate.markdownTemplate, candidate.formattedNotes)
    }

    // MARK: - InsertBehavior

    func testInsertBehaviorCleanupModes() {
        XCTAssertNil(InsertBehavior.alwaysReview.cleanupMode)
        XCTAssertEqual(InsertBehavior.autoInsertRaw.cleanupMode, .raw)
        XCTAssertEqual(InsertBehavior.autoInsertLight.cleanupMode, .light)
        XCTAssertEqual(InsertBehavior.autoInsertPolish.cleanupMode, .polish)
    }

    func testInsertBehaviorDisplayNamesUnique() {
        let labels = Set(InsertBehavior.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, InsertBehavior.allCases.count)
    }

    // MARK: - FocusTargetSnapshot.bundleID

    func testFocusTargetSnapshotIncludesBundleID() {
        let snapshot = FocusTargetSnapshot(
            hasFocusedTextInput: true, hasInsertionCursor: true,
            appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", role: "AXTextField"
        )
        XCTAssertEqual(snapshot.bundleID, "com.tinyspeck.slackmacgap")
    }

    func testFocusTargetUnavailableHasNilBundleID() {
        XCTAssertNil(FocusTargetSnapshot.unavailable.bundleID)
    }

    // MARK: - TranscriptCandidate.timestamp

    func testTranscriptCandidateHasTimestamp() {
        let before = Date()
        let candidate = TranscriptCandidate(
            rawText: "test", lightText: "test", polishText: "test", selectedMode: .raw
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(candidate.timestamp, before)
        XCTAssertLessThanOrEqual(candidate.timestamp, after)
    }

    // MARK: - MeetingCandidate.init(from:)

    func testMeetingCandidateFromResponse() {
        let response = MeetingSummaryResponse(
            transcript: "Full transcript",
            summary: "Meeting summary",
            decisions: ["Ship v2"],
            actionItems: ["Write tests"],
            followUps: ["Check metrics"],
            speakerSegments: [
                MeetingSpeakerSegmentResponse(speaker: "Alice", text: "Hello", utteranceCount: 3),
                MeetingSpeakerSegmentResponse(speaker: "Bob", text: "Hi", utteranceCount: 0)
            ],
            taskOwners: [
                MeetingTaskOwnerResponse(task: "Write tests", owner: "Alice", confidence: 0.85),
                MeetingTaskOwnerResponse(task: "Deploy", owner: "Bob", confidence: 1.5),
                MeetingTaskOwnerResponse(task: "Review", owner: "Carol", confidence: -0.2)
            ],
            markdownExport: "# Export",
            notionExport: "notion block"
        )

        let candidate = MeetingCandidate(from: response)

        XCTAssertEqual(candidate.transcript, "Full transcript")
        XCTAssertEqual(candidate.summary, "Meeting summary")
        XCTAssertEqual(candidate.decisions, ["Ship v2"])
        XCTAssertEqual(candidate.actionItems, ["Write tests"])
        XCTAssertEqual(candidate.followUps, ["Check metrics"])
        XCTAssertFalse(candidate.approved)

        // Speaker segments: utteranceCount clamped to min 1
        XCTAssertEqual(candidate.speakerSegments.count, 2)
        XCTAssertEqual(candidate.speakerSegments[0].utteranceCount, 3)
        XCTAssertEqual(candidate.speakerSegments[1].utteranceCount, 1, "utteranceCount 0 should clamp to 1")

        // Task owners: confidence clamped to [0.0, 1.0]
        XCTAssertEqual(candidate.taskOwners.count, 3)
        XCTAssertEqual(candidate.taskOwners[0].confidence, 0.85, accuracy: 0.001)
        XCTAssertEqual(candidate.taskOwners[1].confidence, 1.0, accuracy: 0.001, "confidence > 1.0 should clamp to 1.0")
        XCTAssertEqual(candidate.taskOwners[2].confidence, 0.0, accuracy: 0.001, "confidence < 0.0 should clamp to 0.0")

        XCTAssertEqual(candidate.markdownExport, "# Export")
        XCTAssertEqual(candidate.notionExport, "notion block")
    }
}
