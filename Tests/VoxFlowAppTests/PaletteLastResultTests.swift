import XCTest
@testable import VoxFlowApp

/// The palette's Last-dictation card (Review Focus 3): Insert Again and Copy
/// act on the newest recent dictation, so they are offered only when the
/// latest receipt is an insertion of that very dictation, and they act on
/// exactly the text the receipt (and the card) shows. After a reject, a voice
/// action, or an insert of other text (a cockpit insert, say) the card never
/// offers an older dictation as if it were the last one.
final class PaletteLastResultTests: XCTestCase {

    // MARK: - canReinsert(receiptIsReject:hasRecentDictation:newestDictationMatchesReceipt:)

    func test_no_reinsert_after_reject() {
        XCTAssertFalse(PaletteLastResult.canReinsert(
            receiptIsReject: true, hasRecentDictation: true, newestDictationMatchesReceipt: true))
    }

    func test_reinsert_after_insert_with_recent() {
        XCTAssertTrue(PaletteLastResult.canReinsert(
            receiptIsReject: false, hasRecentDictation: true, newestDictationMatchesReceipt: true))
    }

    func test_no_reinsert_without_recent() {
        XCTAssertFalse(PaletteLastResult.canReinsert(
            receiptIsReject: false, hasRecentDictation: false, newestDictationMatchesReceipt: true))
    }

    func test_no_reinsert_when_newest_dictation_did_not_produce_the_receipt() {
        XCTAssertFalse(PaletteLastResult.canReinsert(
            receiptIsReject: false, hasRecentDictation: true, newestDictationMatchesReceipt: false))
    }

    // MARK: - Fixtures

    private func receipt(_ json: String) -> CaptureReceipt {
        try! JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    private func dictation(raw: String, light: String, polish: String, selected: CleanupMode = .raw) -> TranscriptCandidate {
        TranscriptCandidate(rawText: raw, lightText: light, polishText: polish, selectedMode: selected)
    }

    /// The newest recent dictation as auto-insert light pushes it: the
    /// candidate says raw is selected, but the light text was inserted.
    private var autoLight: TranscriptCandidate {
        dictation(raw: "draft the update", light: "Draft the update.", polish: "Draft the update for the team.")
    }

    /// Quick dictation's auto-insert receipt, with the source the dictation
    /// pipeline writes ("Inserted (<level · provenance> — <app>)").
    private let insert = #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"Draft the update.","source":"Inserted (light · rules — Notes)","target":"Notes"}"#
    private let cockpitInsert = #"{"event":"insert","ts":"2026-10-31T12:05:00Z","text":"A long cockpit transcript about the roadmap.","source":"cockpit","target":"Notes"}"#
    private let digestInsert = #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text_sha256":"0a1b2c3d4e5f","chars":17,"source":"Inserted (light · rules — Notes)","target":"Notes"}"#
    /// The same text as `insert`, inserted from the cockpit into Mail.
    private let cockpitSameText = #"{"event":"insert","ts":"2026-10-31T12:05:00Z","text":"Draft the update.","source":"cockpit","target":"Mail"}"#
    /// A review insert from the palette (insertCurrentText).
    private let reviewInsert = #"{"event":"insert","ts":"2026-10-31T12:06:00Z","text":"Draft the update.","source":"review (light · rules)","target":"Mail"}"#
    private let reject = #"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"silence","text":""}"#
    private let voiceAction = #"{"event":"computer_action","ts":"2026-10-31T12:00:00Z","action_id":"copy","source":"Copy","outcome":"keyPosted"}"#

    // MARK: - matchedMode(receiptText:candidate:)

    func test_auto_light_insert_matches_the_light_mode() {
        XCTAssertEqual(PaletteLastResult.matchedMode(receiptText: "Draft the update.", candidate: autoLight), .light)
    }

    func test_match_ignores_surrounding_whitespace() {
        XCTAssertEqual(PaletteLastResult.matchedMode(receiptText: " Draft the update.\n", candidate: autoLight), .light)
    }

    func test_identical_texts_keep_the_selected_mode() {
        let same = dictation(raw: "Hello there.", light: "Hello there.", polish: "Hello there.", selected: .polish)
        XCTAssertEqual(PaletteLastResult.matchedMode(receiptText: "Hello there.", candidate: same), .polish)
    }

    func test_other_text_matches_no_mode() {
        XCTAssertNil(PaletteLastResult.matchedMode(receiptText: "A long cockpit transcript.", candidate: autoLight))
    }

    func test_empty_receipt_text_matches_no_mode() {
        let blank = dictation(raw: "", light: " ", polish: "\n")
        XCTAssertNil(PaletteLastResult.matchedMode(receiptText: "", candidate: blank))
        XCTAssertNil(PaletteLastResult.matchedMode(receiptText: "  \n", candidate: blank))
    }

    // MARK: - reinsertCandidate(latest:newest:)

    /// Insert Again and Copy act on exactly the text the receipt shows: the
    /// light text, not the raw text the candidate's selected mode names.
    func test_auto_light_reinsert_acts_on_the_inserted_text() throws {
        var newest = autoLight
        newest.targetProcessIdentifier = 4242
        let latest = receipt(insert)

        let reinsert = try XCTUnwrap(PaletteLastResult.reinsertCandidate(latest: latest, newest: newest))
        XCTAssertEqual(reinsert.selectedMode, .light)
        XCTAssertEqual(reinsert.text(for: reinsert.selectedMode), latest.text)
        // A copy of the same dictation: same identity, texts and original
        // target, which insertRecentDictation resolves the app from.
        XCTAssertEqual(reinsert.id, newest.id)
        XCTAssertEqual(reinsert.rawText, newest.rawText)
        XCTAssertEqual(reinsert.targetProcessIdentifier, 4242)
    }

    /// A cockpit insert writes an insert receipt but adds nothing to the
    /// recent dictations, so the newest one is older than the receipt.
    func test_latest_insert_of_other_text_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(cockpitInsert), newest: autoLight))
    }

    /// Under digest or none retention the receipt carries no text, so the
    /// match cannot be confirmed.
    func test_latest_insert_without_text_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(digestInsert), newest: autoLight))
    }

    func test_latest_reject_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(reject), newest: autoLight))
    }

    /// A voice action inserts no text, so the newest dictation is older than
    /// the last capture.
    func test_latest_voice_action_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(voiceAction), newest: autoLight))
    }

    func test_no_receipt_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: nil, newest: autoLight))
    }

    func test_no_recent_dictation_never_offers_reinsert() {
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(insert), newest: nil))
    }

    // MARK: - Quick dictation receipts (ruling R37)

    /// Codex finding 2: dictate "Draft the update." into Notes, then insert
    /// the same text from the cockpit into Mail. The latest receipt is the
    /// cockpit's, so Insert Again must not act on the older dictation (and
    /// its Notes process).
    func test_same_text_from_another_source_never_reinserts_the_older_dictation() {
        var newest = autoLight
        newest.targetProcessIdentifier = 4242
        XCTAssertNil(PaletteLastResult.reinsertCandidate(latest: receipt(cockpitSameText), newest: newest))
        if case .recent = PaletteLastResult.reinsertAction(
            latest: receipt(cockpitSameText), newest: newest, displayText: "draft the update") {
            XCTFail("the cockpit's receipt pointed Insert Again at the older dictation")
        }
    }

    func test_only_the_dictation_pipelines_insert_counts_as_quick_dictation() {
        XCTAssertTrue(PaletteLastResult.isQuickDictationInsert(receipt(insert)))
        XCTAssertTrue(PaletteLastResult.isQuickDictationInsert(receipt(
            #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"x","source":"Inserted (raw — Notes)"}"#)))
        for source in ["cockpit", "Chain: Tidy", "Re-inserted — Notes", "Snippet 'sig' inserted — Mail",
                       "Prompt inserted (Email — Mail)", "review (light · rules)", "review"] {
            XCTAssertFalse(
                PaletteLastResult.isQuickDictationInsert(receipt(
                    #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"x","source":"\#(source)"}"#)),
                source)
        }
        XCTAssertFalse(PaletteLastResult.isQuickDictationInsert(receipt(
            #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"x"}"#)), "no source")
        XCTAssertFalse(PaletteLastResult.isQuickDictationInsert(receipt(reject)))
        XCTAssertFalse(PaletteLastResult.isQuickDictationInsert(receipt(voiceAction)))
    }

    // MARK: - reinsertAction(latest:newest:displayText:) (rulings R36, R37)

    func test_a_quick_dictation_receipt_reinserts_the_newest_dictation() throws {
        let newest = autoLight
        let action = try XCTUnwrap(PaletteLastResult.reinsertAction(
            latest: receipt(insert), newest: newest, displayText: "draft the update"))
        guard case .recent(let candidate) = action else { return XCTFail("expected the recent dictation, got \(action)") }
        XCTAssertEqual(candidate.id, newest.id)
        XCTAssertEqual(candidate.selectedMode, .light)
    }

    /// Private API results never enter the recent dictations, and a review
    /// insert is not the pipeline's auto-insert: the current result stays
    /// reachable through insertCurrentText and copyCurrentText when the
    /// latest insert's text is the current text.
    func test_falls_back_to_the_current_result_when_the_text_matches() {
        XCTAssertEqual(
            PaletteLastResult.reinsertAction(
                latest: receipt(reviewInsert), newest: nil, displayText: "Draft the update."),
            .current)
        XCTAssertEqual(
            PaletteLastResult.reinsertAction(
                latest: receipt(reviewInsert), newest: autoLight, displayText: "  Draft the update.\n"),
            .current, "trimmed on both sides")
    }

    func test_no_fallback_when_the_current_text_differs() {
        XCTAssertNil(PaletteLastResult.reinsertAction(
            latest: receipt(reviewInsert), newest: nil, displayText: "Something else."))
    }

    func test_no_fallback_after_a_reject_or_a_voice_action() {
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: receipt(reject), newest: nil, displayText: ""))
        XCTAssertNil(PaletteLastResult.reinsertAction(
            latest: receipt(#"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"low_confidence","text":"Draft the update."}"#),
            newest: nil, displayText: "Draft the update."))
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: receipt(voiceAction), newest: nil, displayText: "Copy"))
    }

    func test_no_fallback_with_empty_current_text() {
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: receipt(reviewInsert), newest: nil, displayText: ""))
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: receipt(digestInsert), newest: nil, displayText: ""))
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: receipt(digestInsert), newest: nil, displayText: "x"))
    }

    func test_no_action_without_a_receipt() {
        XCTAssertNil(PaletteLastResult.reinsertAction(latest: nil, newest: autoLight, displayText: "Draft the update."))
    }

    // MARK: - Headline and reason

    func test_reject_headline_says_not_inserted() {
        let row = CaptureReceiptRowModel(receipt: receipt(reject))
        XCTAssertEqual(PaletteLastResult.headline(for: row), VFStatus(.attention, "Not inserted"))
    }

    func test_insert_headline_names_the_target() {
        let row = CaptureReceiptRowModel(receipt: receipt(insert))
        XCTAssertEqual(PaletteLastResult.headline(for: row), VFStatus(.ready, "Inserted in Notes"))
    }

    func test_voice_action_headline_is_neutral() {
        let row = CaptureReceiptRowModel(receipt: receipt(voiceAction))
        XCTAssertEqual(PaletteLastResult.headline(for: row), VFStatus(.info, "Voice action: Shortcut sent"))
    }
}
