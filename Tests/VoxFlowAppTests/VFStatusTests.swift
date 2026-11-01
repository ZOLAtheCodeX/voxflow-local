import XCTest
@testable import VoxFlowApp

final class VFStatusTests: XCTestCase {

    private func palette(
        _ state: SessionState,
        lane: Bool = false,
        ready: Bool = true,
        warming: Bool = false,
        target: Bool = true
    ) -> VFStatus {
        VFStatus.palette(
            sessionState: state,
            isCommandLaneActive: lane,
            dictationReady: ready,
            isWarmingUp: warming,
            hasTextTarget: target
        )
    }

    // MARK: - Palette

    func test_palette_recording_in_voice_control_lane() {
        XCTAssertEqual(
            VFStatus.palette(sessionState: .recording, isCommandLaneActive: true, dictationReady: true, isWarmingUp: false, hasTextTarget: true),
            .voiceControl
        )
    }

    func test_palette_recording() {
        XCTAssertEqual(palette(.recording, lane: false), .listening)
    }

    func test_palette_transcribing() {
        XCTAssertEqual(palette(.transcribing), VFStatus(.working, "Transcribing"))
    }

    func test_palette_inserting() {
        XCTAssertEqual(palette(.inserting), VFStatus(.working, "Inserting"))
    }

    func test_palette_review() {
        XCTAssertEqual(palette(.review), .review)
    }

    func test_palette_onboarding() {
        XCTAssertEqual(palette(.onboarding), VFStatus(.working, "Calibrating"))
    }

    func test_palette_error() {
        XCTAssertEqual(palette(.error), VFStatus(.error, "Failed"))
    }

    func test_palette_idle_warming() {
        XCTAssertEqual(palette(.idle, ready: false, warming: true), .starting)
    }

    func test_palette_idle_not_ready() {
        XCTAssertEqual(palette(.idle, ready: false, warming: false), VFStatus(.attention, "Not ready"))
    }

    func test_palette_idle_no_text_field() {
        XCTAssertEqual(palette(.idle, ready: true, target: false), VFStatus(.attention, "No text field"))
    }

    func test_palette_idle_ready() {
        XCTAssertEqual(palette(.idle, ready: true, target: true), .ready)
    }

    // MARK: - Pill

    func test_pill_visible_only_while_capturing() {
        XCTAssertEqual(VFStatus.pill(sessionState: .recording, isCommandLaneActive: false), .listening)
        XCTAssertEqual(VFStatus.pill(sessionState: .recording, isCommandLaneActive: true), .voiceControl)
        XCTAssertEqual(VFStatus.pill(sessionState: .transcribing, isCommandLaneActive: false), VFStatus(.working, "Transcribing"))
        XCTAssertEqual(VFStatus.pill(sessionState: .inserting, isCommandLaneActive: false), VFStatus(.working, "Inserting"))
        XCTAssertNil(VFStatus.pill(sessionState: .idle, isCommandLaneActive: false))
        XCTAssertNil(VFStatus.pill(sessionState: .review, isCommandLaneActive: false))
        XCTAssertNil(VFStatus.pill(sessionState: .onboarding, isCommandLaneActive: false))
        XCTAssertNil(VFStatus.pill(sessionState: .error, isCommandLaneActive: false))
    }

    // MARK: - Cockpit

    func test_cockpit() {
        XCTAssertEqual(VFStatus.cockpit(.idle), .ready)
        XCTAssertEqual(VFStatus.cockpit(.recording(startedAt: Date(timeIntervalSince1970: 0))), .listening)
        XCTAssertEqual(VFStatus.cockpit(.reviewing), .review)
    }

    // MARK: - Engine and speech model

    func test_engine() {
        var readiness = BackendReadinessState()

        // Not needed: nothing wants it and nothing is running.
        XCTAssertEqual(VFStatus.engine(readiness, backendShouldRun: false), VFStatus(.inactive, "Engine not needed"))

        // Ready.
        readiness.readyForDictation = true
        readiness.processRunning = true
        XCTAssertEqual(VFStatus.engine(readiness, backendShouldRun: true), VFStatus(.ready, "Engine ready"))

        // Warming.
        readiness.readyForDictation = false
        readiness.warmupInProgress = true
        XCTAssertEqual(VFStatus.engine(readiness, backendShouldRun: true), VFStatus(.starting, "Engine starting"))

        // Needed but neither ready nor warming.
        readiness.warmupInProgress = false
        XCTAssertEqual(VFStatus.engine(readiness, backendShouldRun: true), VFStatus(.error, "Engine not ready"))

        // Running while not needed is not "not needed".
        XCTAssertEqual(VFStatus.engine(readiness, backendShouldRun: false), VFStatus(.error, "Engine not ready"))
    }

    func test_speech_model() {
        var readiness = BackendReadinessState()
        XCTAssertEqual(VFStatus.speechModel(readiness), VFStatus(.starting, "Speech model loading"))

        readiness.whisperKitReady = true
        XCTAssertEqual(VFStatus.speechModel(readiness), VFStatus(.ready, "Speech model ready"))

        readiness.whisperKitReady = false
        readiness.readyForDictation = true
        XCTAssertEqual(VFStatus.speechModel(readiness), VFStatus(.ready, "Speech model ready"))
    }

    // MARK: - Vocabulary

    func test_every_kind_has_a_symbol_and_a_label() {
        for kind in VFStatus.Kind.allCases {
            let status = VFStatus(kind, "Label")
            XCTAssertFalse(status.symbol.isEmpty, "\(kind) has no symbol")
            XCTAssertFalse(status.label.isEmpty, "\(kind) has no label")
        }
        for status in [VFStatus.ready, .starting, .listening, .voiceControl, .review] {
            XCTAssertFalse(status.label.isEmpty)
        }
    }

    func test_symbols() {
        XCTAssertEqual(VFStatus(.ready, "x").symbol, "checkmark.circle.fill")
        XCTAssertEqual(VFStatus(.starting, "x").symbol, "hourglass")
        XCTAssertEqual(VFStatus(.listening, "x").symbol, "waveform")
        XCTAssertEqual(VFStatus(.voiceControl, "x").symbol, "command")
        XCTAssertEqual(VFStatus(.working, "x").symbol, "ellipsis.circle")
        XCTAssertEqual(VFStatus(.review, "x").symbol, "text.cursor")
        XCTAssertEqual(VFStatus(.attention, "x").symbol, "exclamationmark.triangle.fill")
        XCTAssertEqual(VFStatus(.error, "x").symbol, "xmark.octagon.fill")
        XCTAssertEqual(VFStatus(.inactive, "x").symbol, "minus.circle")
    }

    func test_only_listening_and_voice_control_are_live() {
        let live = Set(VFStatus.Kind.allCases.filter { VFStatus($0, "x").isLive })
        XCTAssertEqual(live, [.listening, .voiceControl])
    }

    func test_default_labels() {
        XCTAssertEqual(VFStatus.ready.label, "Ready")
        XCTAssertEqual(VFStatus.starting.label, "Starting")
        XCTAssertEqual(VFStatus.listening.label, "Listening")
        XCTAssertEqual(VFStatus.voiceControl.label, "Voice control")
        XCTAssertEqual(VFStatus.review.label, "Review")
    }
}
