import AppKit
import Combine
import SwiftUI

/// What happened to a quick dictation, shown in the pill for a moment after
/// the capture ends (spec decision D2 and amendment 1).
///
/// The order matters and is pinned by `PillOutcomeTests`: an insert result
/// recorded during the capture wins, then an `.error` ending (a failure),
/// then review, then the status line as neutral information. A capture that
/// ends without inserting by design (a voice action, a voice-control
/// command) or a reject is never labeled "Not inserted"; only an insert that
/// actually failed, or an error, is.
enum PillOutcome: Equatable {
    case inserted
    case readyToReview
    case notInserted(message: String)
    case status(message: String)

    static func classify(finalState: SessionState, insertSucceeded: Bool?, statusLine: String) -> PillOutcome? {
        if insertSucceeded == false { return .notInserted(message: statusLine) }
        if insertSucceeded == true { return .inserted }
        // Every path to `.error` ends with nothing inserted: a failure, not information.
        if finalState == .error { return .notInserted(message: statusLine) }
        if finalState == .review { return .readyToReview }
        if statusLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return .status(message: statusLine)
    }

    /// Spoken by VoiceOver when the outcome appears.
    var announcement: String {
        switch self {
        case .inserted: return "Inserted"
        case .readyToReview: return "Ready to review"
        case .notInserted(let message):
            return message.isEmpty ? "Not inserted" : "Not inserted. \(message)"
        case .status(let message): return message
        }
    }

    /// The badge the pill draws. The message outcomes show the status line
    /// verbatim, so no coordinator string is parsed or rewritten.
    var badgeStatus: VFStatus {
        switch self {
        case .inserted: return VFStatus(.ready, "Inserted")
        case .readyToReview: return VFStatus(.review, "Ready to review")
        case .notInserted(let message): return VFStatus(.attention, message.isEmpty ? "Not inserted" : message)
        case .status(let message): return VFStatus(.info, message)
        }
    }

    /// The two outcomes that carry a status line need the wide pill.
    var carriesMessage: Bool {
        switch self {
        case .inserted, .readyToReview: return false
        case .notInserted, .status: return true
        }
    }
}

/// The pill's outcome, observed by `RecordingPillView`. Nil while live.
@MainActor
final class PillPresentation: ObservableObject {
    @Published var outcome: PillOutcome?
}

/// R4.1 — the floating recording pill.
///
/// During capture the user's eyes are on the TARGET app, not the menu bar
/// panel; before this overlay there was zero on-screen feedback while
/// dictating beyond a swapped status-bar symbol. A small non-activating
/// panel floats top-center showing that VoxFlow is listening and for how
/// long; while transcribing it says so. When the capture ends it reports,
/// for `outcomeDuration`, what happened to the dictation, then hides. It
/// never takes key focus, so typing/dictation focus in the target app is
/// untouched, and during the outcome it lets clicks through.
@MainActor
final class RecordingOverlayController {

    /// Non-activating panel that can never become key — the pill is pure
    /// feedback and must not disturb the frozen capture target.
    private final class PillPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private let panel: PillPanel
    private let state: AppState
    private let presentation = PillPresentation()
    private let outcomeDuration: Duration
    private var cancellables: Set<AnyCancellable> = []

    /// True from `.recording` until the capture's outcome is classified, or
    /// until the recording ends without transcribing.
    private var captureActive = false
    /// The insert result recorded during the active capture, if any.
    private var insertSucceeded: Bool?
    private var lastState: SessionState = .idle
    private var classificationPending = false
    /// The deferred classification and then the outcome timer.
    private var outcomeTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }
    var currentOutcome: PillOutcome? { presentation.outcome }

    /// `outcomeDuration` is how long the outcome stays up; `.zero` turns the
    /// outcome state off, so the pill hides as soon as the capture ends.
    init(state: AppState, outcomeDuration: Duration = .milliseconds(1500), onCancel: @escaping () -> Void) {
        self.state = state
        self.outcomeDuration = outcomeDuration
        let size = Self.pillSize(for: nil)
        let panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: RecordingPillView(
            state: state, presentation: presentation, onCancel: onCancel))
        // The controller sizes the panel (220 or 360 pt wide); the view fills it.
        hosting.sizingOptions = []
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.panel = panel

        // @Published emits on willSet, so these read the emitted value rather
        // than `state`, which still holds the old one.
        state.$lastInsertResult
            .dropFirst()
            .sink { [weak self] result in self?.insertResultChanged(result) }
            .store(in: &cancellables)
        state.$statusLine
            .dropFirst()
            .sink { [weak self] line in self?.statusLineChanged(line) }
            .store(in: &cancellables)
    }

    /// Pure geometry: centered horizontally, 12 pt below the menu bar
    /// (Cocoa coordinates, origin bottom-left).
    nonisolated static func pillOrigin(screenFrame: NSRect, visibleFrame: NSRect, pillSize: NSSize) -> NSPoint {
        let x = screenFrame.midX - pillSize.width / 2
        let y = visibleFrame.maxY - 12 - pillSize.height
        return NSPoint(x: x, y: y)
    }

    /// 220 x 32 while live and for the short outcomes; 360 x 32 for an
    /// outcome that shows the status line, which truncates past that width.
    nonisolated static func pillSize(for outcome: PillOutcome?) -> NSSize {
        if let outcome, outcome.carriesMessage {
            return NSSize(width: 360, height: 32)
        }
        return NSSize(width: 220, height: 32)
    }

    func sessionStateChanged(_ newState: SessionState) {
        let previous = lastState
        lastState = newState
        switch newState {
        case .recording:
            beginCapture()
        case .transcribing, .inserting:
            // A review-mode insert is not a capture: no pill.
            guard captureActive else {
                hide()
                return
            }
            cancelPendingClassification()
            showLive()
        case .idle, .review, .onboarding, .error:
            if classificationPending {
                // The classifier reads the latest state when it runs.
                return
            }
            if captureActive, previous == .transcribing || previous == .inserting, outcomeDuration > .zero {
                scheduleClassification()
            } else {
                // A recording that ends without transcribing (a cancel, a
                // press too short to count), or anything outside a capture.
                captureActive = false
                hide()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() {
        outcomeTask?.cancel()
        outcomeTask = nil
        classificationPending = false
        presentation.outcome = nil
        captureActive = true
        insertSucceeded = nil
        showLive()
    }

    private func insertResultChanged(_ result: InsertResult?) {
        guard captureActive, let result else { return }
        insertSucceeded = result.success
    }

    /// A neutral outcome IS the status line, so it follows a status line
    /// written after the session left `.transcribing` (an empty-capture
    /// reject awaits the backend's speech diagnosis before writing its
    /// reason). A failed insert keeps its own message.
    private func statusLineChanged(_ line: String) {
        guard case .status(let shown) = presentation.outcome, line != shown,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let updated = PillOutcome.status(message: line)
        presentation.outcome = updated
        announce(updated)
    }

    private func cancelPendingClassification() {
        guard classificationPending else { return }
        classificationPending = false
        outcomeTask?.cancel()
        outcomeTask = nil
    }

    /// Classify on a later main-actor turn: a coordinator that sets
    /// `lastInsertResult` or `statusLine` just after the session state, in
    /// the same turn, is still seen (Review Focus 1).
    private func scheduleClassification() {
        classificationPending = true
        outcomeTask?.cancel()
        outcomeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await self.presentOutcome()
        }
    }

    private func presentOutcome() async {
        classificationPending = false
        captureActive = false
        guard let outcome = PillOutcome.classify(
            finalState: lastState, insertSucceeded: insertSucceeded, statusLine: state.statusLine
        ) else {
            hide()
            return
        }
        presentation.outcome = outcome
        announce(outcome)
        place(size: Self.pillSize(for: outcome))
        panel.ignoresMouseEvents = true
        if !panel.isVisible { panel.orderFrontRegardless() }

        try? await Task.sleep(for: outcomeDuration)
        // A new capture or a later state change cancels this task; only an
        // outcome that ran its course hides here.
        guard !Task.isCancelled else { return }
        outcomeTask = nil
        hide()
    }

    private func announce(_ outcome: PillOutcome) {
        AccessibilityNotification.Announcement(outcome.announcement).post()
    }

    // MARK: - Panel

    private func showLive() {
        panel.ignoresMouseEvents = false
        let size = Self.pillSize(for: nil)
        if !panel.isVisible || panel.frame.size != size {
            place(size: size)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Sizes the panel and centers it below the menu bar.
    private func place(size: NSSize) {
        guard let screen = NSScreen.main else {
            panel.setContentSize(size)
            return
        }
        let origin = Self.pillOrigin(screenFrame: screen.frame, visibleFrame: screen.visibleFrame, pillSize: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: panel.isVisible)
    }

    private func hide() {
        outcomeTask?.cancel()
        outcomeTask = nil
        classificationPending = false
        presentation.outcome = nil
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
