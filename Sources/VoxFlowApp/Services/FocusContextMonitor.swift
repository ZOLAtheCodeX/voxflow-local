import Foundation

@MainActor
final class FocusContextMonitor {
    private static let pollingInterval: TimeInterval = 0.25

    private let insertService: AccessibilityInsertService
    private var timer: Timer?
    private var lastSnapshot: FocusTargetSnapshot = .unavailable
    private var onUpdate: (@MainActor (FocusTargetSnapshot) -> Void)?
    private(set) var isFrozen = false

    init(insertService: AccessibilityInsertService) {
        self.insertService = insertService
    }

    func start(onUpdate: @MainActor @escaping (FocusTargetSnapshot) -> Void) {
        timer?.invalidate()
        self.onUpdate = onUpdate
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        onUpdate = nil
    }

    func freeze() {
        isFrozen = true
    }

    func unfreeze() {
        isFrozen = false
    }

    private func poll() {
        // Skip the expensive AX call entirely while frozen. `freeze()` is
        // called at capture-start so the focused-target snapshot we already
        // committed (`capturedTargetApp`) stays authoritative for the rest
        // of the session. Polling on the frozen path was wasting an
        // `AXUIElementCopyAttributeValue` pair every 250 ms — the pair runs
        // on the main thread and shows up in the dictation hot-path trace.
        // (Phase 5.5.)
        guard !isFrozen else { return }
        let snapshot = insertService.focusedTargetSnapshot()
        let changed = snapshot.hasFocusedTextInput != lastSnapshot.hasFocusedTextInput
            || snapshot.hasInsertionCursor != lastSnapshot.hasInsertionCursor
            || snapshot.appName != lastSnapshot.appName
            || snapshot.bundleID != lastSnapshot.bundleID
            || snapshot.role != lastSnapshot.role
        lastSnapshot = snapshot
        guard changed else { return }
        onUpdate?(snapshot)
    }
}
