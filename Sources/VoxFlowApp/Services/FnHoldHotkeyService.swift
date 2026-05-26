import AppKit
import Foundation

final class FnHoldHotkeyService {
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

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
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
        let fnAloneNow = Self.isFnAlone(event.modifierFlags)
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
