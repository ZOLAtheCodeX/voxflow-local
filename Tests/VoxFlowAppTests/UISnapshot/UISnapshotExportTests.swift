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

    // The "before" pill is today's real size (156 x 30), not the 220 x 32 of
    // the redesigned pill, so the old view is not stretched.
    private let pillSize = CGSize(width: 156, height: 30)

    func testPillListening() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.recordingDuration = 7
        }
        try SnapshotRenderer.export(RecordingPillView(state: state, onCancel: {}), name: "pill-listening", size: pillSize)
    }

    func testPillVoiceControl() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state {
            $0.sessionState = .recording
            $0.recordingDuration = 3
            $0.isCommandLaneActive = true
        }
        try SnapshotRenderer.export(RecordingPillView(state: state, onCancel: {}), name: "pill-voice-control", size: pillSize)
    }

    func testPillTranscribing() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state { $0.sessionState = .transcribing }
        try SnapshotRenderer.export(RecordingPillView(state: state, onCancel: {}), name: "pill-transcribing", size: pillSize)
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
        let state = UISnapshotFixtures.state { $0.statusLine = "Hold Fn to talk" }
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
        // the harness selects the Recent segment on the live control.
        try SnapshotRenderer.export(
            palette(state, receipts: UISnapshotFixtures.sampleReceiptLines()),
            name: "palette-recent", size: paletteSize, fitHeight: true,
            prepare: { root in
                guard let segments = SnapshotRenderer.firstSubview(of: NSSegmentedControl.self, in: root) else { return }
                segments.selectedSegment = max(0, segments.segmentCount - 1)
                _ = segments.sendAction(segments.action, to: segments.target)
            })
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

    // MARK: - Dashboard

    func testDashboard() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        let state = UISnapshotFixtures.state()
        let receipts = UISnapshotFixtures.receiptStore(lines: UISnapshotFixtures.sampleReceiptLines())
        try SnapshotRenderer.export(
            DashboardWindowView(coordinator: coordinator, state: state, receiptStore: receipts),
            name: "dashboard", size: CGSize(width: 860, height: 720))
    }

    // MARK: - Settings

    private func settingsView(initialTab: SettingsTab) -> SettingsView {
        let stores = UISnapshotFixtures.settingsStores()
        return SettingsView(
            coordinator: coordinator, state: UISnapshotFixtures.state(),
            dictionary: stores.dictionary, snippetStore: stores.snippets,
            chainStore: stores.chains, providerStore: stores.providers,
            initialTab: initialTab, secretLoader: { _ in nil })
    }

    private func exportSettings(_ tab: SettingsTab, name: String) throws {
        try SnapshotRenderer.export(
            settingsView(initialTab: tab), name: "settings-\(name)", size: CGSize(width: 660, height: 560))
    }

    func testSettingsGeneral() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.general, name: "general")
    }

    func testSettingsModels() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.models, name: "models")
    }

    func testSettingsTools() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.tools, name: "tools")
    }

    func testSettingsPrivacy() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.privacy, name: "privacy")
    }

    func testSettingsAdvanced() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.advanced, name: "advanced")
    }

    func testSettingsPermissions() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try exportSettings(.permissions, name: "permissions")
    }

    // MARK: - Setup and welcome

    func testSetup() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try SnapshotRenderer.export(
            SetupWizardView(coordinator: coordinator, state: UISnapshotFixtures.state()),
            name: "setup", size: CGSize(width: 660, height: 720))
    }

    func testWelcome() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["VOXFLOW_UI_SNAPSHOTS"] == nil)
        try SnapshotRenderer.export(
            WelcomeView(coordinator: coordinator, state: UISnapshotFixtures.state()),
            name: "welcome", size: CGSize(width: 420, height: 480))
    }
}
