import XCTest
@testable import VoxFlowApp

final class ExternalAppTrackerTests: XCTestCase {
    private typealias Facts = ExternalAppTracker.RunningAppFacts
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let ownPID: Int32 = 100

    private func lookup(_ table: [Int32: Facts]) -> (Int32) -> Facts? {
        { table[$0] }
    }

    // MARK: - record

    func test_record_ignores_own_pid_nonpositive_pid_nil_bundle_and_nil_launch_date() {
        var tracker = ExternalAppTracker()
        tracker.record(pid: ownPID, bundleID: "com.voxflow", name: "VoxFlow", launchDate: t0, ownPID: ownPID)
        XCTAssertNil(tracker.current)
        tracker.record(pid: 0, bundleID: "com.a", name: "A", launchDate: t0, ownPID: ownPID)
        XCTAssertNil(tracker.current)
        tracker.record(pid: -1, bundleID: "com.a", name: "A", launchDate: t0, ownPID: ownPID)
        XCTAssertNil(tracker.current)
        tracker.record(pid: 5, bundleID: nil, name: "A", launchDate: t0, ownPID: ownPID)
        XCTAssertNil(tracker.current)
        tracker.record(pid: 5, bundleID: "com.a", name: "A", launchDate: nil, ownPID: ownPID)
        XCTAssertNil(tracker.current)
    }

    func test_record_keeps_latest_external_app() {
        var tracker = ExternalAppTracker()
        tracker.record(pid: 5, bundleID: "com.tinyspeck.slackmacgap", name: "Slack", launchDate: t0, ownPID: ownPID)
        tracker.record(pid: 6, bundleID: "com.apple.Notes", name: "Notes", launchDate: t0, ownPID: ownPID)
        XCTAssertEqual(tracker.current?.bundleID, "com.apple.Notes")
        tracker.record(pid: ownPID, bundleID: "com.voxflow", name: "VoxFlow", launchDate: t0, ownPID: ownPID)
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

    // MARK: - currentVerified

    func test_currentVerified_returns_identity_only_when_running_and_matching() {
        var tracker = ExternalAppTracker()
        tracker.record(pid: 5, bundleID: "com.apple.Notes", name: "Notes", launchDate: t0, ownPID: ownPID)

        let match: [Int32: Facts] = [5: ("com.apple.Notes", t0, false)]
        XCTAssertEqual(tracker.currentVerified(lookup: lookup(match)), tracker.current)

        let relaunched: [Int32: Facts] = [5: ("com.apple.Notes", t0.addingTimeInterval(9), false)]
        XCTAssertNil(tracker.currentVerified(lookup: lookup(relaunched)))

        XCTAssertNil(tracker.currentVerified(lookup: lookup([:])))
        XCTAssertNil(ExternalAppTracker().currentVerified(lookup: lookup(match)))
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
