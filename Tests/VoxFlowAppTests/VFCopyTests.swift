import XCTest
@testable import VoxFlowApp

final class VFCopyTests: XCTestCase {
    func test_cleanup_label_degraded() {
        XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: "", model: ""), "Cleanup: local rules, fallback")
    }

    func test_cleanup_label_rules() {
        XCTAssertEqual(
            VFCopy.cleanupProviderLabel(provider: ProviderConfigStore.rulesSentinel, model: ""),
            "Cleanup: local rules"
        )
    }

    func test_cleanup_label_provider() {
        XCTAssertEqual(
            VFCopy.cleanupProviderLabel(provider: "ollama", model: "gemma4:e2b-mlx"),
            "Cleanup: ollama · gemma4:e2b-mlx"
        )
    }

    func test_cleanup_label_no_model() {
        XCTAssertEqual(VFCopy.cleanupProviderLabel(provider: "lmstudio", model: ""), "Cleanup: lmstudio")
    }

    func test_degraded_only_when_empty() {
        XCTAssertTrue(VFCopy.isCleanupDegraded(provider: ""))
        XCTAssertFalse(VFCopy.isCleanupDegraded(provider: ProviderConfigStore.rulesSentinel))
        XCTAssertFalse(VFCopy.isCleanupDegraded(provider: "ollama"))
    }

    func test_hotkey_hint() {
        XCTAssertEqual(
            VFCopy.hotkeyHint(dictation: .fnOnly, voiceControl: .fnCommandSpace),
            "Hold Fn to dictate · Fn + Command + Space for voice control"
        )
    }

    // MARK: - Palette header (ruling R28)

    /// Right after an insert the palette is in the ready state, and the
    /// coordinator has appended its lost-text warning to the status line.
    /// The header used to swap that line for the hotkey hint while ready, so
    /// the warning appeared nowhere. It must be the header's second line.
    func test_header_shows_a_may_be_incomplete_status_line_in_the_ready_state() {
        let line = "Inserted in Notes — may be incomplete (last ~3 s not transcribed)"
        let lines = VFCopy.paletteHeaderLines(statusLine: line, hint: "H", hasReceipt: true)
        XCTAssertEqual(lines.statusLine, line)
        XCTAssertNil(lines.hint, "after the first receipt the hint is not shown")
    }

    func test_header_shows_a_length_limit_warning() {
        let line = "Inserted in Notes — 30 s limit reached; speech after the cutoff was not captured"
        XCTAssertEqual(VFCopy.paletteHeaderLines(statusLine: line, hint: "H", hasReceipt: true).statusLine, line)
    }

    /// First run: no receipt yet, so the hint is a third line under the
    /// status line, which is still shown.
    func test_header_hint_only_before_the_first_receipt() {
        XCTAssertEqual(
            VFCopy.paletteHeaderLines(statusLine: "Hold hotkey to talk", hint: "H", hasReceipt: false),
            PaletteHeaderLines(statusLine: "Hold hotkey to talk", hint: "H"))
        XCTAssertEqual(
            VFCopy.paletteHeaderLines(statusLine: "Backend starting", hint: "H", hasReceipt: true),
            PaletteHeaderLines(statusLine: "Backend starting", hint: nil))
    }

    func test_slow_notice_threshold() {
        XCTAssertNil(VFCopy.slowRunNotice(elapsedSeconds: 14))
        XCTAssertEqual(
            VFCopy.slowRunNotice(elapsedSeconds: 15),
            "Still working. The first run after a pause can take up to a minute while the model loads."
        )
    }

    func test_yes_no() {
        XCTAssertEqual(VFCopy.yesNo("true"), "Yes")
        XCTAssertEqual(VFCopy.yesNo("false"), "No")
        XCTAssertEqual(VFCopy.yesNo(nil), "Unknown")
        XCTAssertEqual(VFCopy.yesNo("ok"), "ok")
    }

    func test_reject_reason_reads_as_words() {
        XCTAssertEqual(VFCopy.rejectReasonText("silence"), "No speech detected")
        XCTAssertEqual(VFCopy.rejectReasonText("hallucination_filter"), "Filtered out as likely not speech")
        XCTAssertEqual(VFCopy.rejectReasonText("some_new_code"), "Some new code")
        XCTAssertEqual(VFCopy.rejectReasonText(nil), "No reason recorded")
        XCTAssertEqual(VFCopy.rejectReasonText(""), "No reason recorded")
    }

    @MainActor
    func test_app_display_name_falls_back_to_bundle_id() {
        XCTAssertEqual(
            SkillProfileSettingsSection.applicationName("local.voxflow.nonexistent"),
            "local.voxflow.nonexistent"
        )
    }
}
