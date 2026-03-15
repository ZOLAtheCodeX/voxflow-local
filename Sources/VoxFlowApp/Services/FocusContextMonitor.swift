import Foundation

@MainActor
final class FocusContextMonitor {
    private static let pollingInterval: TimeInterval = 0.25

    private let insertService: AccessibilityInsertService
    private var timer: DispatchSourceTimer?
    private var lastSnapshot: FocusTargetSnapshot = .unavailable
    private var onUpdate: (@MainActor (FocusTargetSnapshot) -> Void)?
    private(set) var isFrozen = false

    init(insertService: AccessibilityInsertService) {
        self.insertService = insertService
    }

    func start(onUpdate: @MainActor @escaping (FocusTargetSnapshot) -> Void) {
        stop()
        self.onUpdate = onUpdate

        // Poll AX on a background queue to avoid blocking the main run loop.
        // AXUIElementCopyAttributeValue is thread-safe per Apple documentation.
        let service = insertService
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        source.schedule(
            deadline: .now() + Self.pollingInterval,
            repeating: Self.pollingInterval,
            leeway: .milliseconds(50)
        )
        source.setEventHandler { [weak self] in
            let snapshot = service.focusedTargetSnapshot()
            Task { @MainActor [weak self] in
                self?.handleSnapshot(snapshot)
            }
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onUpdate = nil
    }

    func freeze() {
        isFrozen = true
    }

    func unfreeze() {
        isFrozen = false
    }

    private func handleSnapshot(_ snapshot: FocusTargetSnapshot) {
        let changed = snapshot.hasFocusedTextInput != lastSnapshot.hasFocusedTextInput
            || snapshot.hasInsertionCursor != lastSnapshot.hasInsertionCursor
            || snapshot.appName != lastSnapshot.appName
            || snapshot.bundleID != lastSnapshot.bundleID
            || snapshot.role != lastSnapshot.role
        lastSnapshot = snapshot
        guard !isFrozen, changed else { return }
        onUpdate?(snapshot)
    }
}
