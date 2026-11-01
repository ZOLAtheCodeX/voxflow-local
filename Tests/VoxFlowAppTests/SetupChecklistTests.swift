import XCTest
@testable import VoxFlowApp

final class SetupChecklistTests: XCTestCase {

    // MARK: - Progress

    func test_progress_counts_each_finished_row() {
        let p = SetupChecklist.progress(
            microphone: true, accessibility: true, engineReady: false, onboardingPhase: .notStarted)
        XCTAssertEqual(p.doneCount, 2)
        XCTAssertEqual(p.total, 4)
        XCTAssertEqual(p.remainingRequired, 0)
    }

    /// Calibration counts as done only when it ran or was skipped on purpose
    /// (`.complete`); never because it is "not calibrating".
    func test_calibration_is_done_only_when_complete() {
        for phase in [OnboardingPhase.notStarted, .calibrating] {
            let p = SetupChecklist.progress(
                microphone: true, accessibility: true, engineReady: true, onboardingPhase: phase)
            XCTAssertFalse(p.calibration, "\(phase) must not count as done")
            XCTAssertEqual(p.doneCount, 3)
        }
        let done = SetupChecklist.progress(
            microphone: true, accessibility: true, engineReady: true, onboardingPhase: .complete)
        XCTAssertTrue(done.calibration)
        XCTAssertEqual(done.doneCount, 4)
    }

    // MARK: - Engine

    func test_engine_is_ready_from_live_readiness_or_a_fresh_health_check() {
        var readiness = BackendReadinessState()
        XCTAssertFalse(SetupChecklist.engineReady(readiness: readiness, healthCheckReady: false))
        XCTAssertTrue(SetupChecklist.engineReady(readiness: readiness, healthCheckReady: true))
        readiness.whisperKitReady = true
        XCTAssertTrue(SetupChecklist.engineReady(readiness: readiness, healthCheckReady: false))
        readiness.whisperKitReady = false
        readiness.readyForDictation = true
        XCTAssertTrue(SetupChecklist.engineReady(readiness: readiness, healthCheckReady: false))
    }

    // MARK: - Row statuses

    func test_permission_status() {
        XCTAssertEqual(SetupChecklist.permissionStatus(true), VFStatus(.ready, "Granted"))
        XCTAssertEqual(SetupChecklist.permissionStatus(false), VFStatus(.attention, "Needed"))
    }

    func test_engine_status() {
        XCTAssertEqual(SetupChecklist.engineStatus(ready: true, starting: true), VFStatus(.ready, "Ready"))
        XCTAssertEqual(SetupChecklist.engineStatus(ready: false, starting: true), VFStatus(.starting, "Starting"))
        XCTAssertEqual(SetupChecklist.engineStatus(ready: false, starting: false), VFStatus(.attention, "Not ready"))
    }

    func test_calibration_status() {
        XCTAssertEqual(SetupChecklist.calibrationStatus(.complete), VFStatus(.ready, "Done"))
        XCTAssertEqual(SetupChecklist.calibrationStatus(.calibrating), VFStatus(.working, "In progress"))
        XCTAssertEqual(SetupChecklist.calibrationStatus(.notStarted), VFStatus(.inactive, "Not done"))
    }

    // MARK: - Summary and try-it

    func test_summary_names_the_required_steps_left() {
        func summary(mic: Bool, ax: Bool) -> String {
            SetupChecklist.summary(
                SetupProgress(microphone: mic, accessibility: ax, engine: false, calibration: false))
        }
        XCTAssertEqual(summary(mic: true, ax: true), "Required steps are done.")
        XCTAssertEqual(summary(mic: false, ax: true), "1 required step left.")
        XCTAssertEqual(summary(mic: false, ax: false), "2 required steps left.")
    }

    func test_try_it_waits_for_the_required_steps() {
        XCTAssertEqual(
            SetupChecklist.tryIt(remainingRequired: 1, canStartCapture: true, appName: "Notes"),
            VFStatus(.inactive, "Finish the required steps first"))
    }

    func test_try_it_names_the_target_when_ready() {
        XCTAssertEqual(
            SetupChecklist.tryIt(remainingRequired: 0, canStartCapture: true, appName: "Notes"),
            VFStatus(.ready, "Notes is ready"))
        XCTAssertEqual(
            SetupChecklist.tryIt(remainingRequired: 0, canStartCapture: true, appName: nil),
            VFStatus(.ready, "The active app is ready"))
        XCTAssertEqual(
            SetupChecklist.tryIt(remainingRequired: 0, canStartCapture: true, appName: ""),
            VFStatus(.ready, "The active app is ready"))
    }

    func test_try_it_without_a_text_field() {
        XCTAssertEqual(
            SetupChecklist.tryIt(remainingRequired: 0, canStartCapture: false, appName: "Notes"),
            VFStatus(.attention, "No text field detected"))
    }

    // MARK: - Health details

    func test_detail_rows_use_plain_labels_and_yes_no_values() {
        let rows = SetupChecklist.detailRows([
            "service_status": "ok",
            "ready_for_dictation": "true",
            "model_loaded": "false",
            "stt_backend": "whisper",
            "active_stt_model": "openai/whisper-small",
            "stt_fallback_active": "false",
            "offline_mode": "true",
            "issues": "",
        ])
        XCTAssertEqual(rows.map(\.label), [
            "Engine status", "Ready for dictation", "Speech model loaded", "Speech engine",
            "Active model", "Cloud fallback in use", "Offline mode",
        ])
        XCTAssertEqual(rows.map(\.value), [
            "OK", "Yes", "No", "whisper", "openai/whisper-small", "No", "Yes",
        ])
    }

    func test_detail_rows_show_issues_only_when_there_are_some() {
        let rows = SetupChecklist.detailRows(["issues": "model missing; port busy"])
        XCTAssertEqual(rows.last, SetupChecklist.DetailRow(label: "Issues", value: "model missing; port busy"))
    }

    func test_detail_rows_read_unknown_for_a_missing_check() {
        let rows = SetupChecklist.detailRows([:])
        XCTAssertEqual(rows.count, 7)
        XCTAssertTrue(rows.allSatisfy { $0.value == "Unknown" })
    }

    func test_health_message() {
        XCTAssertEqual(
            SetupChecklist.healthMessage(reachable: true, ready: true, firstIssue: nil),
            "Engine ready: the speech model is loaded.")
        XCTAssertEqual(
            SetupChecklist.healthMessage(reachable: true, ready: false, firstIssue: "model missing"),
            "Engine reachable but not ready: model missing")
        XCTAssertEqual(
            SetupChecklist.healthMessage(reachable: true, ready: false, firstIssue: nil),
            "Engine reachable but not ready: the speech model is not loaded.")
        XCTAssertEqual(
            SetupChecklist.healthMessage(reachable: false, ready: false, firstIssue: nil),
            "Engine unreachable. Choose Start Engine, then Check Again.")
    }
}
