import AppKit
import XCTest
@testable import VoxFlowApp

/// A live, identifiable app for read-only target fixtures: Finder when it
/// runs (always, in a login session, so it cannot quit mid-test), else the
/// first app with a bundle ID and a launch date. launchd starts Finder, not
/// LaunchServices, so Finder has no launch date; `requiringLaunchDate` skips
/// it. Nothing is ever sent to the app. Shared by the cockpit test files.
func liveAppFixture(requiringLaunchDate: Bool = false) throws -> NSRunningApplication {
    let running = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier != nil && !$0.isTerminated
    }
    let finder = running.first {
        $0.bundleIdentifier == "com.apple.finder" && (!requiringLaunchDate || $0.launchDate != nil)
    }
    guard let app = finder ?? running.first(where: { $0.launchDate != nil }) else {
        throw XCTSkip("no identifiable running app available")
    }
    return app
}

final class ExternalAppTrackerTests: XCTestCase {
    private typealias Facts = ExternalAppTracker.RunningAppFacts
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ownPID: Int32 = 100

    private func lookup(_ table: [Int32: Facts]) -> (Int32) -> Facts? {
        { table[$0] }
    }

    // MARK: - record

    private func trackingSlack() -> ExternalAppTracker {
        var tracker = ExternalAppTracker()
        tracker.record(
            pid: 5, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", launchDate: t0,
            isRegularApp: true, ownPID: ownPID)
        return tracker
    }

    func test_record_ignores_own_pid_and_nonpositive_pid() {
        var tracker = trackingSlack()
        tracker.record(pid: ownPID, bundleID: "com.voxflow", name: "VoxFlow", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.tinyspeck.slackmacgap")
        tracker.record(pid: 0, bundleID: "com.a", name: "A", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.tinyspeck.slackmacgap")
        tracker.record(pid: -1, bundleID: "com.a", name: "A", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.tinyspeck.slackmacgap")
    }

    /// Agents and accessory popups (menu-bar extras, Spotlight-style panels)
    /// activate without being where the user types; they never move the target.
    func test_record_ignores_non_regular_apps() {
        var tracker = trackingSlack()
        tracker.record(pid: 7, bundleID: "com.example.menuextra", name: "Extra", launchDate: t0, isRegularApp: false, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.tinyspeck.slackmacgap")
        tracker.record(pid: 8, bundleID: nil, name: nil, launchDate: nil, isRegularApp: false, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.tinyspeck.slackmacgap")
    }

    /// The newest regular app is the target. When it cannot be identified,
    /// keeping the older app would insert into an app the user left, so the
    /// next ⌘R gets no target and falls back to the clipboard.
    func test_record_clears_target_for_unidentifiable_regular_app() {
        var noBundle = trackingSlack()
        noBundle.record(pid: 9, bundleID: nil, name: "Odd", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertNil(noBundle.current)

        var noLaunchDate = trackingSlack()
        noLaunchDate.record(pid: 9, bundleID: "com.odd", name: "Odd", launchDate: nil, isRegularApp: true, ownPID: ownPID)
        XCTAssertNil(noLaunchDate.current)
    }

    func test_record_keeps_latest_external_app() {
        var tracker = trackingSlack()
        tracker.record(pid: 6, bundleID: "com.apple.Notes", name: "Notes", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.apple.Notes")
        tracker.record(pid: ownPID, bundleID: "com.voxflow", name: "VoxFlow", launchDate: t0, isRegularApp: true, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.apple.Notes")
    }

    // MARK: - resolveTarget

    func test_resolveTarget_matching_bundle_and_launch_date_resolves() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0, false)]
        XCTAssertEqual(
            ExternalAppTracker.resolveTarget(
                pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)),
            5)
    }

    func test_resolveTarget_reused_pid_with_other_bundle_is_nil() {
        let table: [Int32: Facts] = [5: ("com.other.App", t0, false)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)))
    }

    func test_resolveTarget_relaunch_on_reused_pid_is_nil() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(5), false)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)))
    }

    func test_resolveTarget_terminated_app_is_nil() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0, true)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)))
    }

    func test_resolveTarget_nil_pid_is_nil() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0, false)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: nil, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)))
    }

    func test_resolveTarget_nil_expected_bundle_is_nil() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0, false)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: nil, expectedLaunchDate: t0, lookup: lookup(table)))
    }

    func test_resolveTarget_nil_expected_launch_date_checks_bundle_only() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(500), false)]
        XCTAssertEqual(
            ExternalAppTracker.resolveTarget(
                pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: nil, lookup: lookup(table)),
            5)
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: "com.other", expectedLaunchDate: nil, lookup: lookup(table)))
    }

    /// Sessions persist dates at one-second resolution, so a sub-second
    /// difference must still verify the right app.
    func test_resolveTarget_tolerates_subsecond_launch_date_difference() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(0.4), false)]
        XCTAssertEqual(
            ExternalAppTracker.resolveTarget(
                pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)),
            5)
    }

    func test_resolveTarget_nil_actual_launch_date_with_expected_date_is_nil() {
        let table: [Int32: Facts] = [5: ("com.apple.Notes", nil, false)]
        XCTAssertNil(ExternalAppTracker.resolveTarget(
            pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table)))
    }

    /// Pins the 1.0 s tolerance from both sides, in both directions.
    func test_resolveTarget_launch_date_tolerance_is_one_second() {
        func resolve(offset: TimeInterval) -> Int32? {
            let table: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(offset), false)]
            return ExternalAppTracker.resolveTarget(
                pid: 5, expectedBundleID: "com.apple.Notes", expectedLaunchDate: t0, lookup: lookup(table))
        }
        XCTAssertEqual(resolve(offset: 0.9), 5)
        XCTAssertEqual(resolve(offset: -0.9), 5)
        XCTAssertNil(resolve(offset: 1.5))
        XCTAssertNil(resolve(offset: -1.5))
    }

    // MARK: - currentVerified

    func test_currentVerified_returns_identity_only_when_running_and_matching() {
        var tracker = ExternalAppTracker()
        tracker.record(pid: 5, bundleID: "com.apple.Notes", name: "Notes", launchDate: t0, isRegularApp: true, ownPID: ownPID)

        let match: [Int32: Facts] = [5: ("com.apple.Notes", t0, false)]
        XCTAssertEqual(tracker.currentVerified(lookup: lookup(match)), tracker.current)

        let relaunched: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(9), false)]
        XCTAssertNil(tracker.currentVerified(lookup: lookup(relaunched)))

        XCTAssertNil(tracker.currentVerified(lookup: lookup([:])))
        XCTAssertNil(ExternalAppTracker().currentVerified(lookup: lookup(match)))
    }

    // MARK: - liveRunningApp

    private func snapshot(of app: NSRunningApplication, bundleID: String?) -> FocusTargetSnapshot {
        FocusTargetSnapshot(
            hasFocusedTextInput: false, hasInsertionCursor: false,
            appName: app.localizedName, bundleID: bundleID, role: nil,
            processIdentifier: app.processIdentifier, launchDate: app.launchDate)
    }

    /// One object is constructed, its own facts are verified, and that same
    /// object is returned: a second construction from the pid could describe
    /// a different process than the one just verified.
    @MainActor
    func test_liveRunningApp_verifies_and_returns_the_one_object_it_constructs() throws {
        let app = try liveAppFixture()
        var constructed: [NSRunningApplication] = []
        let resolved = ExternalAppTracker.liveRunningApp(
            for: snapshot(of: app, bundleID: app.bundleIdentifier),
            runningApp: { pid in
                let made = NSRunningApplication(processIdentifier: pid)
                if let made { constructed.append(made) }
                return made
            })

        XCTAssertEqual(constructed.count, 1)
        XCTAssertTrue(resolved === constructed.first)
        XCTAssertEqual(resolved?.processIdentifier, app.processIdentifier)
    }

    @MainActor
    func test_liveRunningApp_refuses_a_live_pid_with_another_identity() throws {
        let app = try liveAppFixture(requiringLaunchDate: true)
        let bundleID = try XCTUnwrap(app.bundleIdentifier)
        XCTAssertNotNil(ExternalAppTracker.liveRunningApp(for: snapshot(of: app, bundleID: bundleID)))
        XCTAssertNil(ExternalAppTracker.liveRunningApp(for: snapshot(of: app, bundleID: bundleID + ".not-this")))
        XCTAssertNil(ExternalAppTracker.liveRunningApp(for: snapshot(of: app, bundleID: nil)))
        var relaunched = snapshot(of: app, bundleID: bundleID)
        relaunched.launchDate = app.launchDate?.addingTimeInterval(-60)
        XCTAssertNil(ExternalAppTracker.liveRunningApp(for: relaunched))
    }

    // MARK: - Snapshot

    func test_targetSnapshot_carries_identity_without_text_input_flags() {
        let identity = ExternalAppIdentity(pid: 5, bundleID: "com.apple.Notes", name: "Notes", launchDate: t0)
        let snapshot = identity.targetSnapshot
        XCTAssertEqual(snapshot.processIdentifier, 5)
        XCTAssertEqual(snapshot.bundleID, "com.apple.Notes")
        XCTAssertEqual(snapshot.appName, "Notes")
        XCTAssertEqual(snapshot.launchDate, t0)
        XCTAssertFalse(snapshot.hasFocusedTextInput)
        XCTAssertFalse(snapshot.hasInsertionCursor)
        XCTAssertNil(snapshot.role)
    }

    func test_snapshot_without_launchDate_key_still_decodes() throws {
        let json = """
        {"hasFocusedTextInput":false,"hasInsertionCursor":false,"appName":null,"bundleID":null,"role":null,"processIdentifier":null}
        """
        let snapshot = try JSONDecoder().decode(FocusTargetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.launchDate)
        XCTAssertEqual(snapshot, .unavailable)
    }
}
