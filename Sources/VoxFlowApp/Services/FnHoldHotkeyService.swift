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
    private let activationDelay: TimeInterval

    init(activationDelay: TimeInterval = 0.12) {
        self.activationDelay = activationDelay
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
            schedulePressTrigger()
            return
        }

        pendingPressWorkItem?.cancel()
        pendingPressWorkItem = nil

        guard hasTriggeredPress else { return }
        hasTriggeredPress = false
        onRelease?()
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
