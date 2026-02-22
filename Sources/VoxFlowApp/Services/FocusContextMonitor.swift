import Foundation

@MainActor
final class FocusContextMonitor {
    private static let pollingInterval: TimeInterval = 0.25

    private let insertService: AccessibilityInsertService
    private var timer: Timer?
    private var lastSnapshot: FocusTargetSnapshot = .unavailable
    private var onUpdate: (@MainActor (FocusTargetSnapshot) -> Void)?

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

    private func poll() {
        let snapshot = insertService.focusedTargetSnapshot()
        let changed = snapshot.hasFocusedTextInput != lastSnapshot.hasFocusedTextInput
            || snapshot.hasInsertionCursor != lastSnapshot.hasInsertionCursor
            || snapshot.appName != lastSnapshot.appName
            || snapshot.bundleID != lastSnapshot.bundleID
            || snapshot.role != lastSnapshot.role
        lastSnapshot = snapshot
        if changed {
            onUpdate?(snapshot)
        }
    }
}
