import XCTest
@testable import VoxFlowApp

/// The window-open notifications (⌥⌘V hotkey, menu-panel buttons, voice
/// commands, protocol steps) must route through an app-lifetime handler on
/// the coordinator — NOT a view-bound `.onReceive`. The original wiring put
/// the only listener on WelcomeView, so closing the Welcome window silently
/// killed the cockpit hotkey (2026-06-12 user report).
@MainActor
final class WindowOpenRoutingTests: XCTestCase {

    func testCockpitNotificationOpensCockpitAndRoutesWindowID() {
        let coordinator = AppCoordinator.shared
        coordinator.cockpit.close()
        var opened: [String] = []
        coordinator.installWindowOpenHandler { opened.append($0) }

        NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)

        XCTAssertEqual(opened, ["cockpit"])
        XCTAssertTrue(coordinator.state.cockpitVisible)
        coordinator.cockpit.close()
    }

    func testDashboardAndSetupNotificationsRouteWindowIDs() {
        let coordinator = AppCoordinator.shared
        var opened: [String] = []
        coordinator.installWindowOpenHandler { opened.append($0) }

        NotificationCenter.default.post(name: .voxflowOpenDashboard, object: nil)
        NotificationCenter.default.post(name: .voxflowOpenSetup, object: nil)

        XCTAssertEqual(opened, ["dashboard", "setup"])
    }

    func testReinstallingHandlerReplacesItWithoutDoubleFiring() {
        let coordinator = AppCoordinator.shared
        coordinator.cockpit.close()
        var first: [String] = []
        var second: [String] = []
        coordinator.installWindowOpenHandler { first.append($0) }
        coordinator.installWindowOpenHandler { second.append($0) }

        NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, ["cockpit"])
        coordinator.cockpit.close()
    }
}
