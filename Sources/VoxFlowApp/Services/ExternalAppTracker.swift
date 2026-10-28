import AppKit
import Foundation

/// An app other than VoxFlow that the user was last working in. The launch
/// date pairs with the pid so a recycled pid is never mistaken for the app.
struct ExternalAppIdentity: Equatable, Sendable {
    let pid: Int32
    let bundleID: String
    let name: String?
    let launchDate: Date

    /// A target snapshot carrying identity only: no text-input flags, no role.
    var targetSnapshot: FocusTargetSnapshot {
        FocusTargetSnapshot(
            hasFocusedTextInput: false,
            hasInsertionCursor: false,
            appName: name,
            bundleID: bundleID,
            role: nil,
            processIdentifier: pid,
            launchDate: launchDate
        )
    }
}

/// Remembers the last activated non-VoxFlow app, so the cockpit can freeze it
/// at record time (the cockpit window itself is frontmost by then). Pure value
/// type (ruling R5); its owner is main-actor.
struct ExternalAppTracker: Sendable {
    typealias RunningAppFacts = (bundleID: String?, launchDate: Date?, terminated: Bool)

    /// Launch dates survive a persisted-session round trip at one-second
    /// resolution, so an exact comparison would reject the right app.
    private static let launchDateTolerance: TimeInterval = 1.0

    private(set) var current: ExternalAppIdentity?

    /// `isRegularApp` is `activationPolicy == .regular`. VoxFlow itself, a
    /// pid-less app and a non-regular app (agents, accessory popups) never
    /// move the target. The newest regular app is the target; when it cannot
    /// be identified (no bundle ID or no launch date) there is none, so the
    /// next ⌘R falls back to the clipboard instead of an app the user left.
    mutating func record(
        pid: Int32, bundleID: String?, name: String?, launchDate: Date?,
        isRegularApp: Bool, ownPID: Int32
    ) {
        guard pid > 0, pid != ownPID, isRegularApp else { return }
        guard let bundleID, let launchDate else {
            current = nil
            return
        }
        current = ExternalAppIdentity(pid: pid, bundleID: bundleID, name: name, launchDate: launchDate)
    }

    /// The tracked app, only if that pid still runs the same app instance.
    func currentVerified(lookup: (Int32) -> RunningAppFacts?) -> ExternalAppIdentity? {
        guard let current else { return nil }
        let pid = Self.resolveTarget(
            pid: current.pid,
            expectedBundleID: current.bundleID,
            expectedLaunchDate: current.launchDate,
            lookup: lookup)
        return pid == nil ? nil : current
    }

    /// Returns the pid only when it still belongs to the app the snapshot
    /// named. A pid alone is not identity: the OS recycles pids, and a stale
    /// one would insert into an unrelated app. A nil expected bundle means no
    /// target (ruling R6).
    static func resolveTarget(
        pid: Int32?,
        expectedBundleID: String?,
        expectedLaunchDate: Date?,
        lookup: (Int32) -> RunningAppFacts?
    ) -> Int32? {
        guard let pid, let expectedBundleID,
              let facts = lookup(pid),
              !facts.terminated,
              facts.bundleID == expectedBundleID else { return nil }
        if let expectedLaunchDate {
            guard let actual = facts.launchDate,
                  abs(actual.timeIntervalSince(expectedLaunchDate)) <= launchDateTolerance
            else { return nil }
        }
        return pid
    }

    static func liveLookup(_ pid: Int32) -> RunningAppFacts? {
        NSRunningApplication(processIdentifier: pid).map(facts(of:))
    }

    private static func facts(of app: NSRunningApplication) -> RunningAppFacts {
        (app.bundleIdentifier, app.launchDate, app.isTerminated)
    }

    /// Rebuilds the frozen target as an ``NSRunningApplication`` at insert
    /// time without consulting the frontmost app (which is the cockpit
    /// window itself by then). Nil when the pid no longer runs the same app.
    /// Exactly one object is constructed: its own facts are verified and
    /// that same object is returned, so the verified process is the one the
    /// insert gets. `runningApp` is the construction seam for tests.
    @MainActor
    static func liveRunningApp(
        for snapshot: FocusTargetSnapshot?,
        runningApp: (Int32) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
    ) -> NSRunningApplication? {
        guard let snapshot, let pid = snapshot.processIdentifier,
              let app = runningApp(pid) else { return nil }
        let verified = resolveTarget(
            pid: pid,
            expectedBundleID: snapshot.bundleID,
            expectedLaunchDate: snapshot.launchDate,
            lookup: { $0 == pid ? facts(of: app) : nil })
        return verified == nil ? nil : app
    }
}
