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

    func test_second_line_ready_shows_hint() {
        XCTAssertEqual(VFCopy.paletteSecondLine(status: .ready, hint: "H", statusLine: "Inserted"), "H")
    }

    func test_second_line_otherwise_shows_status_line() {
        XCTAssertEqual(
            VFCopy.paletteSecondLine(status: .starting, hint: "H", statusLine: "Backend starting"),
            "Backend starting"
        )
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

    @MainActor
    func test_app_display_name_falls_back_to_bundle_id() {
        XCTAssertEqual(
            SkillProfileSettingsSection.applicationName("local.voxflow.nonexistent"),
            "local.voxflow.nonexistent"
        )
    }
}
