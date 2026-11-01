import XCTest
@testable import VoxFlowApp

/// The palette's Last-dictation card (Review Focus 3): Insert Again and Copy
/// act on the newest recent dictation, so they are offered only when the
/// latest receipt is an insertion of that very dictation. After a reject, a
/// voice action, or an insert of other text (a cockpit insert, say) the card
/// never offers an older dictation as if it were the last one.
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

    // MARK: - matches(receiptText:candidateTexts:)

    func test_matches_trimmed_receipt_text_against_any_candidate_text() {
        XCTAssertTrue(PaletteLastResult.matches(
            receiptText: " Draft the update.\n",
            candidateTexts: ["draft the update", "Draft the update.", "Draft the update for the team."]))
    }

    func test_no_match_when_no_candidate_text_equals_the_receipt() {
        XCTAssertFalse(PaletteLastResult.matches(
            receiptText: "A long cockpit transcript.",
            candidateTexts: ["draft the update", "Draft the update."]))
    }

    func test_empty_receipt_text_never_matches() {
        XCTAssertFalse(PaletteLastResult.matches(receiptText: "", candidateTexts: ["", "Draft the update."]))
        XCTAssertFalse(PaletteLastResult.matches(receiptText: "  \n", candidateTexts: ["", " "]))
    }

    // MARK: - From the latest receipt and the newest recent dictation

    private func receipt(_ json: String) -> CaptureReceipt {
        try! JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    private func dictation(raw: String, light: String, polish: String, selected: CleanupMode = .raw) -> TranscriptCandidate {
        TranscriptCandidate(rawText: raw, lightText: light, polishText: polish, selectedMode: selected)
    }

    /// The newest recent dictation: raw is selected, but light was inserted.
    private var newest: TranscriptCandidate {
        dictation(raw: "draft the update", light: "Draft the update.", polish: "Draft the update for the team.")
    }

    private let insert = #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"Draft the update.","target":"Notes"}"#
    private let cockpitInsert = #"{"event":"insert","ts":"2026-10-31T12:05:00Z","text":"A long cockpit transcript about the roadmap.","target":"Notes"}"#
    private let digestInsert = #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text_sha256":"0a1b2c3d4e5f","chars":17,"target":"Notes"}"#
    private let reject = #"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"silence","text":""}"#
    private let voiceAction = #"{"event":"computer_action","ts":"2026-10-31T12:00:00Z","action_id":"copy","source":"Copy","outcome":"keyPosted"}"#

    func test_latest_insert_of_the_newest_dictation_offers_reinsert() {
        XCTAssertTrue(PaletteLastResult.canReinsert(latest: receipt(insert), newest: newest))
    }

    /// A cockpit insert writes an insert receipt but adds nothing to the
    /// recent dictations, so the newest one is older than the receipt.
    func test_latest_insert_of_other_text_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(cockpitInsert), newest: newest))
    }

    /// Under digest or none retention the receipt carries no text, so the
    /// match cannot be confirmed.
    func test_latest_insert_without_text_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(digestInsert), newest: newest))
    }

    func test_latest_reject_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(reject), newest: newest))
    }

    /// A voice action inserts no text, so the newest dictation is older than
    /// the last capture.
    func test_latest_voice_action_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(voiceAction), newest: newest))
    }

    func test_no_receipt_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: nil, newest: newest))
    }

    func test_no_recent_dictation_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(insert), newest: nil))
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

    func test_reject_reason_reads_as_words() {
        XCTAssertEqual(PaletteLastResult.rejectReasonText("silence"), "No speech detected")
        XCTAssertEqual(PaletteLastResult.rejectReasonText("hallucination_filter"), "Filtered out as likely not speech")
        XCTAssertEqual(PaletteLastResult.rejectReasonText("some_new_code"), "Some new code")
        XCTAssertEqual(PaletteLastResult.rejectReasonText(nil), "No reason recorded")
    }
}
