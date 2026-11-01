import AppKit
import SwiftUI
import XCTest
@testable import VoxFlowApp

/// Renders today's views to PNG for the UI refresh (before and after images).
/// Tooling, not assertions: every test is skipped unless `VOXFLOW_UI_SNAPSHOTS`
/// names an absolute output directory.
///
///     VOXFLOW_UI_SNAPSHOTS=$PWD/docs/superpowers/images/<set> \
///         swift test --filter UISnapshotExportTests
@MainActor
final class UISnapshotExportTests: XCTestCase {

    override func tearDown() async throws {
        UISnapshotFixtures.removeTempDirectories()
    }

    private var coordinator: AppCoordinator { AppCoordinator.shared }

    // MARK: - Recording pill

    // The pill at the size `RecordingOverlayController` gives it: 220 x 32
    // live and for the short outcomes, 360 x 32 for an outcome that shows
    // the status line. (The committed "before" images are today's 156 x 30.)
    private func exportPill(_ state: AppState, outcome: PillOutcome? = nil, name: String) throws {
        let presentation = PillPresentation()
        presentation.outcome = outcome
        try SnapshotRenderer.export(
            RecordingPillView(state: state, presentation: presentation, onCancel: {})
                .environment(\.vfPrefersMaterialSurfaces, true),
            name: name, size: RecordingOverlayController.pillSize(for: outcome))
    }

    func testPillListening() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.recordingDuration = 7
        }
        try exportPill(state, name: "pill-listening")
    }

    func testPillVoiceControl() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.recordingDuration = 3
            $0.isCommandLaneActive = true
        }
        try exportPill(state, name: "pill-voice-control")
    }

    func testPillTranscribing() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state { $0.sessionState = .transcribing }
        try exportPill(state, name: "pill-transcribing")
    }

    func testPillOutcomeInserted() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportPill(UISnapshotFixtures.state(), outcome: .inserted, name: "pill-outcome-inserted")
    }

    func testPillOutcomeReview() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state { $0.sessionState = .review }
        try exportPill(state, outcome: .readyToReview, name: "pill-outcome-review")
    }

    func testPillOutcomeNotInserted() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state { $0.sessionState = .review }
        try exportPill(
            state, outcome: .notInserted(message: "Insert failed. Copied to clipboard."),
            name: "pill-outcome-not-inserted")
    }

    /// A neutral status long enough to truncate (Review Focus 5).
    func testPillOutcomeStatus() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let message = "Speech detected but not recognized. Try speaking closer to the microphone (audio kept)"
        try exportPill(UISnapshotFixtures.state(), outcome: .status(message: message), name: "pill-outcome-status")
    }

    // MARK: - Command palette

    private let paletteSize = CGSize(width: 430, height: 600)

    private func palette(_ state: AppState, receipts: [String]) -> CommandPaletteView {
        CommandPaletteView(
            coordinator: coordinator, state: state,
            receiptStore: UISnapshotFixtures.receiptStore(lines: receipts))
    }

    func testPaletteIdle() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        // The recent dictation lets the Last-dictation card offer Insert
        // Again; the old palette showed recent dictations only under Recent,
        // so the before image is unaffected.
        let state = UISnapshotFixtures.state {
            $0.statusLine = "Hold Fn to talk"
            $0.recentDictations = [
                UISnapshotFixtures.candidate("Draft the quarterly update for the design team.", minutesAgo: 4),
            ]
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-idle", size: paletteSize, fitHeight: true)
    }

    func testPaletteReview() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let text = "Draft the quarterly update for the design team."
        let state = UISnapshotFixtures.state {
            $0.sessionState = .review
            $0.statusLine = "Review ready"
            $0.selectedMode = .light
            $0.transcriptCandidate = UISnapshotFixtures.candidate(text, minutesAgo: 0)
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-review", size: paletteSize, fitHeight: true)
    }

    func testPaletteRecording() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.statusLine = "Listening"
            $0.recordingDuration = 4.2
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-recording", size: paletteSize, fitHeight: true)
    }

    func testPaletteTranscribing() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .transcribing
            $0.statusLine = "Transcribing"
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-transcribing", size: paletteSize, fitHeight: true)
    }

    func testPaletteRecent() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.statusLine = "Hold Fn to talk"
            $0.recentDictations = [
                UISnapshotFixtures.candidate("Draft the quarterly update for the design team.", minutesAgo: 4),
                UISnapshotFixtures.candidate("Remind the team that the onboarding flow ships next sprint.", minutesAgo: 18),
                UISnapshotFixtures.candidate("Add the accessibility review to Thursday's agenda.", minutesAgo: 42),
            ]
        }
        // The active panel is private view state with no injection seam, so
        // the harness selects the Recent segment (the last one of the
        // palette's only segmented control, Dictate | Recent) on the live
        // control.
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-recent", size: paletteSize, fitHeight: true,
            prepare: { root in
                guard let segments = SnapshotRenderer.firstSubview(of: NSSegmentedControl.self, in: root) else { return }
                segments.selectedSegment = max(0, segments.segmentCount - 1)
                _ = segments.sendAction(segments.action, to: segments.target)
            })
    }

    /// Review Focus 3: the newest receipt is a reject while recent
    /// dictations exist. The card shows the reason and no Insert Again.
    func testPaletteAfterReject() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.statusLine = "No speech detected. Try again."
            $0.recentDictations = [
                UISnapshotFixtures.candidate("Draft the quarterly update for the design team.", minutesAgo: 4),
            ]
        }
        let now = Date()
        let reject = #"{"event":"reject","ts":"\#(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)))","reason":"silence","source":"Rejected (silence)","audio_seconds":1.4,"rms":0.002,"audio_file":"/tmp/voxflow-snapshot-reject.wav"}"#
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines(now: now) + [reject]),
            name: "palette-after-reject", size: paletteSize, fitHeight: true)
    }

    /// Review Focus 5: a 300-character status line and a long target name
    /// stay on one line each, tail-truncated.
    func testPaletteLongStrings() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.backendReadiness.readyForDictation = false
            $0.backendReadiness.whisperKitReady = false
            $0.statusLine = String(repeating: "Speech model still loading after a long pause, please wait. ", count: 5)
            $0.focusTarget = FocusTargetSnapshot(
                hasFocusedTextInput: true, hasInsertionCursor: true, appName: "Microsoft Outlook (PWA)",
                bundleID: "com.example.outlook-pwa", role: "AXTextArea", processIdentifier: nil)
            $0.autoSubmitMode = .both
            $0.providerMode = .privateAPI
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-long-strings", size: paletteSize, fitHeight: true)
    }

    /// The privacy preview is a consent gate: warning banner and outline.
    func testPalettePrivacyReview() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .review
            $0.providerMode = .privateAPI
            $0.privateAPIBaseURL = "https://api.example.com"
            $0.privateAPIModel = "example-model"
            $0.privateAPIKeyConfigured = true
            $0.statusLine = "Review privacy preview and approve request"
            $0.privacyPreview = PrivacyPreview(
                operation: .cleanup, token: "snapshot",
                originalText: "Call Alex at 555 0100 about the invoice.",
                redactedText: "Call [NAME] at [PHONE] about the invoice.")
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-privacy", size: paletteSize, fitHeight: true)
    }

    func testPaletteVoiceControl() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.isCommandLaneActive = true
            $0.statusLine = "Listening for a command"
            $0.recordingDuration = 2.4
        }
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-voice-control", size: paletteSize, fitHeight: true)
    }

    // MARK: - Cockpit

    private let cockpitSize = CGSize(width: 960, height: 620)

    private func cockpitView(_ fixture: CockpitFixture) -> CockpitWindowView {
        CockpitWindowView(
            coordinator: fixture.coordinator, state: fixture.state, sessionService: fixture.session,
            cockpitCapture: fixture.capture, dictionary: fixture.dictionary, chainStore: fixture.chains)
    }

    func testCockpitEmpty() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let fixture = UISnapshotFixtures.cockpit(state: UISnapshotFixtures.state(), transcript: nil)
        try SnapshotRenderer.export(cockpitView(fixture), name: "cockpit-empty", size: cockpitSize)
    }

    func testCockpitReview() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let transcript = "Draft the quarterly update for the design team. Mention the new onboarding flow, "
            + "the two open accessibility fixes, and the review scheduled for Thursday afternoon."
        let fixture = UISnapshotFixtures.cockpit(state: UISnapshotFixtures.state(), transcript: transcript)
        try SnapshotRenderer.export(cockpitView(fixture), name: "cockpit-review", size: cockpitSize)
    }

    /// Recording: the top bar reads "Listening" with the elapsed time.
    func testCockpitListening() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        // A fresh install still shows the voice-keyword banner.
        let state = UISnapshotFixtures.state { $0.totalCaptureCount = 2; $0.voicePromptStripDismissed = false }
        let fixture = UISnapshotFixtures.cockpit(state: state, transcript: nil)
        fixture.session.start(targetApp: state.focusTarget)
        fixture.session.setTranscript("Draft the quarterly update for the design team. Mention the new onboarding flow")
        try SnapshotRenderer.export(cockpitView(fixture), name: "cockpit-listening", size: cockpitSize)
    }

    /// A long transcript wraps inside the reading width, with an action
    /// running (the in-flight chip) and a wide window to show the centering.
    func testCockpitLongTranscript() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let paragraph = "Draft the quarterly update for the design team. Mention the new onboarding flow, "
            + "the two open accessibility fixes, and the review scheduled for Thursday afternoon. "
            + "Then call out that the cockpit now has a proper reading surface with a capped line length, "
            + "so a long dictation stays comfortable to read and to edit before it is inserted."
        let transcript = [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        let state = UISnapshotFixtures.state {
            $0.smartActionInFlight = .memo
            $0.smartActionStartedAt = Date().addingTimeInterval(-4)
        }
        let fixture = UISnapshotFixtures.cockpit(state: state, transcript: transcript)
        try SnapshotRenderer.export(
            cockpitView(fixture), name: "cockpit-long-transcript", size: CGSize(width: 1180, height: 700))
    }

    // MARK: - Dashboard

    func testDashboard() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state()
        let receipts = UISnapshotFixtures.receiptStore(lines: UISnapshotFixtures.sampleReceiptLines())
        try SnapshotRenderer.export(
            DashboardWindowView(coordinator: coordinator, state: state, receiptStore: receipts),
            name: "dashboard", size: CGSize(width: 860, height: 720))
    }

    /// Experimental modes on (Approvals, mode usage and benchmark show), a
    /// reject whose audio was kept, and a degraded cleanup chain.
    func testDashboardExperimental() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let clip = UISnapshotFixtures.makeTempDirectory().appendingPathComponent("rejected.wav")
        try Data([0]).write(to: clip)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-9 * 60))
        let reject =
            #"{"event":"reject","ts":"\#(stamp)","reason":"low_confidence","source":"Rejected (low_confidence)","audio_seconds":4.2,"rms":0.03,"audio_file":"\#(clip.path)"}"#
        let state = UISnapshotFixtures.state {
            $0.translationModeEnabled = true
            $0.meetingModeEnabled = true
            $0.approvedTranslationCount = 3
            $0.approvedMeetingCount = 1
            $0.privacyApproveRawCount = 1
            $0.privacyApproveRedactedCount = 3
            $0.workflowCaptureCounts = [.dictation: 38, .translateEnToDe: 3, .meeting: 1]
            $0.backendReadiness.activePolishProvider = ""
            $0.backendReadiness.activePolishModel = ""
            $0.benchmarkHistoryByProfile = [
                .translateGemma4B: TranslationBenchmarkHistoryStats(
                    profile: .translateGemma4B, benchmarkRuns: 4, successfulRuns: 4, placeholderRuns: 0,
                    totalMedianLatencyMs: 4 * 820, totalP95LatencyMs: 4 * 1_300,
                    lastMedianLatencyMs: 800, lastP95LatencyMs: 1_250)
            ]
        }
        let receipts = UISnapshotFixtures.receiptStore(
            lines: UISnapshotFixtures.sampleReceiptLines(now: now) + [reject])
        try SnapshotRenderer.export(
            DashboardWindowView(coordinator: coordinator, state: state, receiptStore: receipts),
            name: "dashboard-experimental", size: CGSize(width: 860, height: 1340))
    }

    // MARK: - Settings

    private func settingsView(initialTab: SettingsTab, state: AppState = UISnapshotFixtures.state()) -> SettingsView {
        let stores = UISnapshotFixtures.settingsStores()
        return SettingsView(
            coordinator: coordinator, state: state,
            dictionary: stores.dictionary, snippetStore: stores.snippets,
            chainStore: stores.chains, providerStore: stores.providers,
            initialTab: initialTab, secretLoader: { _ in nil })
    }

    private func exportSettings(_ tab: SettingsTab, name: String, state: AppState = UISnapshotFixtures.state()) throws {
        try SnapshotRenderer.export(
            settingsView(initialTab: tab, state: state), name: "settings-\(name)", size: CGSize(width: 660, height: 560))
    }

    func testSettingsGeneral() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.general, name: "general")
    }

    func testSettingsApps() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.appProfiles = [
                "com.apple.Notes": AppProfile(tone: .neutral, cleanupMode: .light, insertBehavior: .autoInsertLight),
                "com.apple.Terminal": AppProfile(tone: .concise, cleanupMode: .raw, insertBehavior: .autoInsertRaw),
                "com.apple.mail": AppProfile(tone: .formal, cleanupMode: .light, insertBehavior: .alwaysReview),
                "com.example.notinstalled": AppProfile(tone: .neutral, cleanupMode: .raw, insertBehavior: .alwaysReview),
            ]
        }
        try exportSettings(.apps, name: "apps", state: state)
    }

    func testSettingsVoice() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.voice, name: "voice")
    }

    func testSettingsModels() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.models, name: "models")
    }

    func testSettingsPrivacy() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.privacy, name: "privacy")
    }

    func testSettingsAdvanced() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.advanced, name: "advanced")
    }

    // MARK: - Setup and welcome

    func testSetup() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try SnapshotRenderer.export(
            SetupWizardView(coordinator: coordinator, state: UISnapshotFixtures.state()),
            name: "setup", size: CGSize(width: 660, height: 720))
    }

    /// The engine is down and no text field is focused: Start Engine shows,
    /// the status reads "Not ready", and the try-it badge warns. (The two
    /// permission rows follow this machine's real grants.)
    func testSetupEngineDown() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.backendReadiness = BackendReadinessState()
            $0.focusTarget = FocusTargetSnapshot(
                hasFocusedTextInput: false, hasInsertionCursor: false, appName: nil,
                bundleID: nil, role: nil, processIdentifier: nil)
            $0.targetingMode = .textFieldOnly
        }
        try SnapshotRenderer.export(
            SetupWizardView(coordinator: coordinator, state: state),
            name: "setup-engine-down", size: CGSize(width: 660, height: 560))
    }

    /// Calibration in progress: the phrase card and its buttons sit under the row.
    func testSetupCalibrating() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.onboardingPhase = .calibrating
            $0.calibrationItems = [
                CalibrationItem(
                    expectedPhrase: "The quick brown fox jumps over the lazy dog",
                    heardPhrase: "The quick brown fox", score: 0.81),
                CalibrationItem(
                    expectedPhrase: "Please schedule a review for Thursday afternoon",
                    heardPhrase: nil, score: nil),
            ]
            $0.activeCalibrationIndex = 1
        }
        try SnapshotRenderer.export(
            SetupWizardView(coordinator: coordinator, state: state),
            name: "setup-calibrating", size: CGSize(width: 660, height: 760))
    }

    func testWelcome() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try SnapshotRenderer.export(
            WelcomeView(coordinator: coordinator, state: UISnapshotFixtures.state()),
            name: "welcome", size: CGSize(width: 420, height: 480))
    }
}
