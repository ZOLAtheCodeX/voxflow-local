import AppKit
import Foundation

/// Thread-safety invariant: all mutable state (isFnAlonePressed,
/// hasTriggeredPress, pendingPressWorkItem) is touched only on the main
/// thread — the local monitor and the activation-delay work item already run
/// there, and the global-monitor callback hops to main below (audit S6).
/// @unchecked Sendable documents that confinement for the @Sendable
/// global-monitor closure; it is not free-threaded.
final class FnHoldHotkeyService: @unchecked Sendable {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var isFnAlonePressed = false
    private var hasTriggeredPress = false
    private var pendingPressWorkItem: DispatchWorkItem?
    private var pendingReleaseWorkItem: DispatchWorkItem?
    private let activationDelay: TimeInterval
    private let releaseGraceDelay: TimeInterval

    /// `releaseGraceDelay`: release-side debounce. A flags flicker mid-hold
    /// (brushed modifier while fn stays down) used to fire onRelease
    /// INSTANTLY — truncating the capture mid-utterance — and the follow-up
    /// re-press was then swallowed by the .transcribing guard, losing the
    /// rest of the utterance (session 29; matches the 0.4-0.8 s receipts
    /// fired 1.2-1.6 s after a previous capture). Release now fires only if
    /// fn is still up when the grace window closes; a flicker that resolves
    /// back to fn-alone is a non-event and the capture continues seamlessly.
    init(activationDelay: TimeInterval = 0.12, releaseGraceDelay: TimeInterval = 0.15) {
        self.activationDelay = activationDelay
        self.releaseGraceDelay = releaseGraceDelay
    }

    func register(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        unregister()

        self.onPress = onPress
        self.onRelease = onRelease

        // Global-monitor callbacks can arrive off the main thread; all state
        // (isFnAlonePressed / hasTriggeredPress) is otherwise touched on main
        // (local monitor + the scheduled DispatchWorkItem). Hop to main so
        // every mutation is serialized — audit S6 data race.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            // Extract the Sendable flags before hopping — NSEvent itself
            // must not cross threads.
            let flags = event.modifierFlags
            if Thread.isMainThread {
                self?.handleFlags(flags)
            } else {
                DispatchQueue.main.async { self?.handleFlags(flags) }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    func unregister() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        pendingPressWorkItem?.cancel()
        pendingPressWorkItem = nil
        pendingReleaseWorkItem?.cancel()
        pendingReleaseWorkItem = nil
        globalMonitor = nil
        localMonitor = nil
        onPress = nil
        onRelease = nil
        isFnAlonePressed = false
        hasTriggeredPress = false
    }

    deinit {
        unregister()
    }

    func handleFlagsChanged(_ event: NSEvent) {
        handleFlags(event.modifierFlags)
    }

    private func handleFlags(_ flags: NSEvent.ModifierFlags) {
        let fnAloneNow = Self.isFnAlone(flags)
        guard fnAloneNow != isFnAlonePressed else { return }

        isFnAlonePressed = fnAloneNow
        if fnAloneNow {
            // Back to fn-alone. If a release is pending (grace window open),
            // this is a flicker resolving — absorb it: no release, no
            // re-press, the capture continues.
            if let pendingReleaseWorkItem {
                pendingReleaseWorkItem.cancel()
                self.pendingReleaseWorkItem = nil
                return
            }
            schedulePressTrigger()
            return
        }

        pendingPressWorkItem?.cancel()
        pendingPressWorkItem = nil

        guard hasTriggeredPress else { return }
        scheduleReleaseTrigger()
    }

    /// Release fires only if fn is STILL up when the grace window closes —
    /// a mid-hold flags flicker used to truncate the capture instantly.
    private func scheduleReleaseTrigger() {
        pendingReleaseWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isFnAlonePressed, self.hasTriggeredPress else { return }
            self.pendingReleaseWorkItem = nil
            self.hasTriggeredPress = false
            self.onRelease?()
        }

        pendingReleaseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + releaseGraceDelay, execute: workItem)
    }

    private func schedulePressTrigger() {
        pendingPressWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isFnAlonePressed, !self.hasTriggeredPress else { return }
            self.hasTriggeredPress = true
            self.onPress?()
        }

        pendingPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay, execute: workItem)
    }

    private static func isFnAlone(_ flags: NSEvent.ModifierFlags) -> Bool {
        let relevantFlags = flags.intersection([.command, .option, .control, .shift, .capsLock, .function])
        return relevantFlags == [.function]
    }
}
