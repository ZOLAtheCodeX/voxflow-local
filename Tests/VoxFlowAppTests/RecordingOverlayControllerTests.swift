import XCTest
@testable import VoxFlowApp

/// R4.1: the floating recording pill. All recording feedback previously
/// lived inside the 430 px menu bar panel — while dictating into another
/// app there was zero on-screen feedback beyond the status-bar symbol.
@MainActor
final class RecordingOverlayControllerTests: XCTestCase {

    func testHiddenInitially() {
        let controller = RecordingOverlayController(state: AppState(), onCancel: {})
        XCTAssertFalse(controller.isVisible)
    }

    func testShowsForRecordingAndTranscribingHidesOtherwise() {
        let controller = RecordingOverlayController(state: AppState(), onCancel: {})
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.transcribing)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.review)
        XCTAssertFalse(controller.isVisible)
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.isVisible)
        controller.sessionStateChanged(.idle)
        XCTAssertFalse(controller.isVisible)
    }

    func testPillPositionIsTopCenterBelowMenuBar() {
        // Pure geometry: pill centered horizontally, 12 pt below the menu bar.
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 944) // menu bar = 38 pt
        let pill = NSSize(width: 280, height: 60)
        let origin = RecordingOverlayController.pillOrigin(screenFrame: screen, visibleFrame: visible, pillSize: pill)
        XCTAssertEqual(origin.x, (1512 - 280) / 2, accuracy: 0.5)
        // Cocoa origin is bottom-left: top of pill should sit 12 pt below the
        // visible-frame top (944), so origin.y = 944 - 12 - 60.
        XCTAssertEqual(origin.y, 944 - 12 - 60, accuracy: 0.5)
    }

    func testPanelNeverActivatesOrStealsKey() {
        let controller = RecordingOverlayController(state: AppState(), onCancel: {})
        controller.sessionStateChanged(.recording)
        XCTAssertTrue(controller.panelForTesting.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.panelForTesting.canBecomeKey)
    }
}
