import XCTest
@testable import VoxFlowApp

/// Read-model side of InsertionAuditLog: one JSONL line -> one typed receipt.
/// Decoding is lenient by design — the schema grew over time, so every field
/// beyond event/ts is optional and type mismatches nil the field, not the line.
final class CaptureReceiptTests: XCTestCase {

    private func decode(_ json: String) -> CaptureReceipt? {
        try? JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    func testDecodesInsertLine() {
        let r = decode(#"{"event":"insert","ts":"2026-07-12T19:00:00Z","text":"hello world","source":"Inserted (light · rules — app)","target":"Notes","confidence":0.91,"audio_seconds":3.4}"#)
        XCTAssertEqual(r?.event, .insert)
        XCTAssertEqual(r?.text, "hello world")
        XCTAssertEqual(r?.target, "Notes")
        XCTAssertEqual(r?.confidence, 0.91)
        XCTAssertEqual(r?.audioSeconds, 3.4)
    }

    func testDecodesRejectLineWithAudioFile() {
        let r = decode(#"{"event":"reject","ts":"2026-07-09T17:20:44Z","text":"","reason":"empty","confidence":0.0,"audio_seconds":0.86,"source":"quick_dictation","rms":0.015,"audio_file":"/tmp/reject.wav"}"#)
        XCTAssertEqual(r?.event, .reject)
        XCTAssertEqual(r?.reason, "empty")
        XCTAssertEqual(r?.rms, 0.015)
        XCTAssertEqual(r?.audioFile, "/tmp/reject.wav")
    }

    /// The writer sanitizes NaN/Inf to the string "non-finite" so the record
    /// survives; the reader must nil that FIELD without dropping the LINE.
    func testNonFiniteSentinelNilsTheFieldNotTheLine() {
        let r = decode(#"{"event":"reject","ts":"2026-07-09T17:20:44Z","reason":"empty","rms":"non-finite"}"#)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.rms)
        XCTAssertEqual(r?.reason, "empty")
    }

    func testMissingTsFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"insert","text":"hi"}"#))
    }

    func testUnknownEventFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"banana","ts":"2026-07-12T19:00:00Z"}"#))
    }

    func testMalformedJSONFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"insert","ts":"#))
    }

    func testFractionalSecondsTimestampParses() {
        let r = decode(#"{"event":"insert","ts":"2026-07-12T19:00:00.123Z","text":"x"}"#)
        XCTAssertNotNil(r?.ts)
    }
}

/// Structured view of the audit `source` display label.
final class SourceLabelTests: XCTestCase {

    func testLightRulesApp() {
        let l = SourceLabel.parse("Inserted (light · rules — app)")
        XCTAssertEqual(l.tokens, ["light", "rules"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testPolishModelTerminal() {
        let l = SourceLabel.parse("Inserted (polish · gemma4:e2b-mlx — Terminal)")
        XCTAssertEqual(l.tokens, ["polish", "gemma4:e2b-mlx"])
        XCTAssertEqual(l.appLabel, "Terminal")
    }

    func testRawNoProvenance() {
        let l = SourceLabel.parse("Inserted (raw — app)")
        XCTAssertEqual(l.tokens, ["raw"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testLegacyLightWithoutProvenanceToken() {
        let l = SourceLabel.parse("Inserted (light — app)")
        XCTAssertEqual(l.tokens, ["light"])
        XCTAssertEqual(l.appLabel, "app")
    }

    /// Tone joins the mode token with ", " (not " · ") — it must stay fused
    /// to the mode token, not become its own chip.
    func testToneVariantStaysFusedToModeToken() {
        let l = SourceLabel.parse("Inserted (light, friendly · rules — app)")
        XCTAssertEqual(l.tokens, ["light, friendly", "rules"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testNonInsertSourcePassesThroughAsSingleToken() {
        let l = SourceLabel.parse("quick_dictation")
        XCTAssertEqual(l.tokens, ["quick_dictation"])
        XCTAssertNil(l.appLabel)
    }

    func testEmptySourceYieldsNoTokens() {
        let l = SourceLabel.parse("")
        XCTAssertEqual(l.tokens, [])
        XCTAssertNil(l.appLabel)
    }

    /// Documents the label grammar inline: mirrors the interpolation in
    /// DictationWorkflowCoordinator.autoInsertOrReview (currently line ~271):
    ///   "Inserted (\(mode)\(toneLabel)\(provenanceTag) — \(appLabel))"
    /// The REAL pinning (real code path) is the round-trip test added to
    /// DictationWorkflowCoordinatorTests below.
    func testPinsDictationWorkflowLabelFormat() {
        let mode = "light"
        let toneLabel = ", friendly"
        let provenanceTag = " · rules"
        let appLabel = "app"
        let source = "Inserted (\(mode)\(toneLabel)\(provenanceTag) — \(appLabel))"
        let parsed = SourceLabel.parse(source)
        XCTAssertEqual(parsed.tokens, ["light, friendly", "rules"])
        XCTAssertEqual(parsed.appLabel, "app")
    }
}
