import XCTest
@testable import VoxFlowApp

/// The palette's Last-dictation card (Review Focus 3): Insert Again and Copy
/// act on the newest recent dictation, so they are offered only when the
/// latest receipt is an insertion. After a reject the card shows the reason
/// and never offers an older dictation as if it were the last one.
final class PaletteLastResultTests: XCTestCase {

    // MARK: - canReinsert(receiptIsReject:hasRecentDictation:)

    func test_no_reinsert_after_reject() {
        XCTAssertFalse(PaletteLastResult.canReinsert(receiptIsReject: true, hasRecentDictation: true))
    }

    func test_reinsert_after_insert_with_recent() {
        XCTAssertTrue(PaletteLastResult.canReinsert(receiptIsReject: false, hasRecentDictation: true))
    }

    func test_no_reinsert_without_recent() {
        XCTAssertFalse(PaletteLastResult.canReinsert(receiptIsReject: false, hasRecentDictation: false))
    }

    // MARK: - From the latest receipt

    private func receipt(_ json: String) -> CaptureReceipt {
        try! JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    private let insert = #"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"Draft the update.","target":"Notes"}"#
    private let reject = #"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"silence","text":""}"#
    private let voiceAction = #"{"event":"computer_action","ts":"2026-10-31T12:00:00Z","action_id":"copy","source":"Copy","outcome":"keyPosted"}"#

    func test_latest_insert_offers_reinsert() {
        XCTAssertTrue(PaletteLastResult.canReinsert(latest: receipt(insert), hasRecentDictation: true))
    }

    func test_latest_reject_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(reject), hasRecentDictation: true))
    }

    /// A voice action inserts no text, so the newest dictation is older than
    /// the last capture.
    func test_latest_voice_action_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: receipt(voiceAction), hasRecentDictation: true))
    }

    func test_no_receipt_never_offers_reinsert() {
        XCTAssertFalse(PaletteLastResult.canReinsert(latest: nil, hasRecentDictation: true))
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
