import XCTest
@testable import VoxFlowApp

/// The Dashboard's conditional sections and row wording, pinned as pure
/// rules: health first, recent captures second, and experimental-mode cards
/// only when those modes are in use.
final class DashboardRulesTests: XCTestCase {

    // MARK: - Approvals card

    func test_approvals_hidden_when_neither_translate_nor_meeting_is_on() {
        XCTAssertFalse(DashboardRules.showsApprovals(translationEnabled: false, meetingEnabled: false))
    }

    func test_approvals_shown_when_translate_or_meeting_is_on() {
        XCTAssertTrue(DashboardRules.showsApprovals(translationEnabled: true, meetingEnabled: false))
        XCTAssertTrue(DashboardRules.showsApprovals(translationEnabled: false, meetingEnabled: true))
        XCTAssertTrue(DashboardRules.showsApprovals(translationEnabled: true, meetingEnabled: true))
    }

    // MARK: - Mode usage and benchmark

    func test_experimental_sections_hidden_by_default() {
        XCTAssertFalse(DashboardRules.showsExperimentalSections(
            translationEnabled: false, meetingEnabled: false, promptEnabled: false, hasBenchmarkHistory: false))
    }

    func test_experimental_sections_shown_for_each_experimental_mode() {
        XCTAssertTrue(DashboardRules.showsExperimentalSections(
            translationEnabled: true, meetingEnabled: false, promptEnabled: false, hasBenchmarkHistory: false))
        XCTAssertTrue(DashboardRules.showsExperimentalSections(
            translationEnabled: false, meetingEnabled: true, promptEnabled: false, hasBenchmarkHistory: false))
        XCTAssertTrue(DashboardRules.showsExperimentalSections(
            translationEnabled: false, meetingEnabled: false, promptEnabled: true, hasBenchmarkHistory: false))
    }

    func test_experimental_sections_shown_when_benchmark_history_exists() {
        XCTAssertTrue(DashboardRules.showsExperimentalSections(
            translationEnabled: false, meetingEnabled: false, promptEnabled: false, hasBenchmarkHistory: true))
    }

    // MARK: - App compatibility

    private func stats(success: Int, fallback: Int = 0, failed: Int = 0) -> AppInsertStats {
        AppInsertStats(appName: "App", successCount: success, fallbackCount: fallback, failedCount: failed)
    }

    func test_compatibility_levels() {
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 0)).label, "No data")
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 20)).label, "Excellent")
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 9, failed: 1)).label, "Good")
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 7, failed: 3)).label, "Needs tuning")
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 1, failed: 3)).label, "Unstable")
    }

    func test_good_uses_the_info_token_not_raw_blue() {
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 9, failed: 1)).color, VF.colorInfo)
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 20)).color, VF.colorSuccess)
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 7, failed: 3)).color, VF.colorWarning)
        XCTAssertEqual(DashboardRules.compatibility(for: stats(success: 1, failed: 3)).color, VF.colorError)
    }

    // MARK: - Recent capture rows

    private func row(_ json: String) -> CaptureReceiptRowModel {
        let receipt = try! JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
        return CaptureReceiptRowModel(receipt: receipt)
    }

    func test_insert_second_line_quotes_the_snippet() {
        let insert = row(#"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"Draft the update.","target":"Notes"}"#)
        XCTAssertEqual(DashboardRules.secondLine(for: insert, audioAvailable: false), "\u{201C}Draft the update.\u{201D}")
    }

    func test_reject_second_line_is_the_reason_in_words() {
        let reject = row(#"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"silence","text":""}"#)
        XCTAssertEqual(DashboardRules.secondLine(for: reject, audioAvailable: false), "No speech detected")
    }

    func test_reject_second_line_says_when_audio_is_kept() {
        let reject = row(#"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"low_confidence","audio_file":"/tmp/a.wav"}"#)
        XCTAssertEqual(
            DashboardRules.secondLine(for: reject, audioAvailable: true), "Recognition confidence too low \u{00B7} Audio kept")
        XCTAssertEqual(
            DashboardRules.secondLine(for: reject, audioAvailable: false), "Recognition confidence too low")
    }

    func test_reject_without_a_reason_says_so() {
        let reject = row(#"{"event":"reject","ts":"2026-10-31T12:00:00Z"}"#)
        XCTAssertEqual(DashboardRules.secondLine(for: reject, audioAvailable: false), "No reason recorded")
    }

    func test_insert_without_text_has_an_empty_second_line() {
        let digest = row(#"{"event":"insert","ts":"2026-10-31T12:00:00Z","text_sha256":"0a1b","chars":17,"target":"Notes"}"#)
        XCTAssertEqual(DashboardRules.secondLine(for: digest, audioAvailable: false), "")
    }

    func test_reject_drops_the_raw_rejected_chip() {
        let reject = row(#"{"event":"reject","ts":"2026-10-31T12:00:00Z","reason":"silence","source":"Rejected (silence)"}"#)
        XCTAssertEqual(DashboardRules.chips(for: reject), [])
    }

    func test_insert_keeps_its_chips() {
        let insert = row(#"{"event":"insert","ts":"2026-10-31T12:00:00Z","text":"Hi.","source":"Inserted (light · rules — app)","target":"Notes"}"#)
        XCTAssertEqual(DashboardRules.chips(for: insert), insert.chips)
        XCTAssertFalse(insert.chips.isEmpty)
    }

    func test_failed_voice_action_keeps_action_and_outcome_chips() {
        let failed = row(#"{"event":"computer_action","ts":"2026-10-31T12:00:00Z","action_id":"copy","source":"Copy","outcome":"failed"}"#)
        XCTAssertTrue(failed.isReject)
        XCTAssertEqual(DashboardRules.chips(for: failed), ["Voice action", "Failed"])
    }

    func test_computer_action_chip_uses_the_glossary_term() {
        XCTAssertEqual(DashboardRules.chipText("Computer action"), "Voice action")
        XCTAssertEqual(DashboardRules.chipText("light"), "light")
    }
}
