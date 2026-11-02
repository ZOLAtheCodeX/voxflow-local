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
    /// True while a finished capture waits for a late status line (ruling
    /// R29): the session is already idle, but the pill keeps its working row
    /// rather than report the line written at `.transcribing` entry.
    @Published var awaitingLateStatus = false
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
///
/// Late status lines (ruling R29, which supersedes R5): an empty-capture
/// reject turns the session idle, then awaits the backend's speech diagnosis
/// before it writes its reason, so the classifier can still see the line
/// written at `.transcribing` entry ("Transcribing..."). The pill then keeps
/// its working row for up to `lateStatusHold` and shows the first new line
/// with a full outcome window, or hides with no outcome if none comes. Any
/// other neutral outcome follows at most one later status line, restarting
/// its window. A new capture cancels all of it at once. The status line the
/// focus monitor writes right after a focus change ("Ready in X", rulings
/// R35 and R53) is not about the capture: it neither ends the hold nor uses
/// the follow.
@MainActor
final class RecordingOverlayController {

    /// Non-activating panel that can never become key — the pill is pure
    /// feedback and must not disturb the frozen capture target.
    private final class PillPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Where the pill is once a capture has been classified.
    private enum AfterCapture {
        /// Live, or nothing on screen.
        case none
        /// The classifier saw `heldLine`, the line written at `.transcribing`
        /// entry: the working row stays up while the pill waits for a new one.
        case awaitingLateStatus(heldLine: String)
        /// An outcome is up. `follows` is how many later status lines a
        /// neutral outcome may still take: one after a direct classification,
        /// none after a late line.
        case showing(follows: Int)
    }

    private let panel: PillPanel
    private let state: AppState
    private let presentation = PillPresentation()
    private let outcomeDuration: Duration
    private let lateStatusHold: Duration
    private let announce: @MainActor (String) -> Void
    private var cancellables: Set<AnyCancellable> = []

    /// True from `.recording` until the capture's outcome is classified, or
    /// until the recording ends without transcribing.
    private var captureActive = false
    /// The insert result recorded during the active capture, if any.
    private var insertSucceeded: Bool?
    private var lastState: SessionState = .idle
    private var classificationPending = false
    /// The deferred classification, then the hold or outcome timer.
    private var outcomeTask: Task<Void, Never>?
    private var afterCapture: AfterCapture = .none
    /// The status line current at `.transcribing` entry for this capture.
    private var transcribingLine: String?
    private var transcribingLineTask: Task<Void, Never>?
    /// Set when `focusTarget` changes; the next status line consumes it and
    /// is ignored (ruling R53). `AppCoordinator.startFocusMonitoring` writes
    /// the focus target and then, synchronously and only while the session
    /// is idle, its own status line, and the focus monitor is frozen during
    /// a capture, so the line right after a focus change is the focus line.
    /// It is recognised by that order, never by its words. Capture start and
    /// hiding the pill clear a mark that no line consumed.
    private var focusLinePending = false

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }
    var currentOutcome: PillOutcome? { presentation.outcome }
    var transcribingLineForTesting: String? { transcribingLine }

    /// True while the pill waits for a late status line (no outcome yet).
    var isHoldingForStatusLine: Bool {
        if case .awaitingLateStatus = afterCapture { return true }
        return false
    }

    /// `outcomeDuration` is how long the outcome stays up; `.zero` turns the
    /// outcome state off, so the pill hides as soon as the capture ends.
    /// `lateStatusHold` is the longest the pill waits for a late status line.
    /// `announce` speaks each outcome to VoiceOver; tests pass a recorder.
    init(
        state: AppState,
        outcomeDuration: Duration = .milliseconds(1500),
        lateStatusHold: Duration = .seconds(3),
        onCancel: @escaping () -> Void,
        announce: @escaping @MainActor (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
    ) {
        self.state = state
        self.outcomeDuration = outcomeDuration
        self.lateStatusHold = lateStatusHold
        self.announce = announce
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
        state.$focusTarget
            .dropFirst()
            .sink { [weak self] _ in self?.focusTargetChanged() }
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
            if newState == .transcribing, previous == .recording {
                recordTranscribingLine()
            }
            showLive()
        case .idle, .review, .onboarding, .error:
            if classificationPending {
                // The classifier reads the latest state when it runs.
                return
            }
            if captureActive, previous == .transcribing || previous == .inserting, outcomeDuration > .zero {
                // Every capture that reached `.transcribing`, including a
                // press too short to count and a canceled transcription
                // (ruling R10), is classified.
                scheduleClassification()
            } else {
                // A recording canceled before it was transcribed, or
                // anything outside a capture.
                captureActive = false
                hide()
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture() {
        outcomeTask?.cancel()
        outcomeTask = nil
        transcribingLineTask?.cancel()
        transcribingLineTask = nil
        transcribingLine = nil
        focusLinePending = false
        classificationPending = false
        afterCapture = .none
        presentation.outcome = nil
        presentation.awaitingLateStatus = false
        captureActive = true
        insertSucceeded = nil
        showLive()
    }

    /// The coordinator publishes `.transcribing` before it writes the line
    /// that goes with it ("Transcribing...") in the same step, so the line is
    /// read once now and again on the next main-actor turn, while the session
    /// is still transcribing.
    private func recordTranscribingLine() {
        transcribingLine = state.statusLine
        transcribingLineTask?.cancel()
        transcribingLineTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.captureActive, self.lastState == .transcribing else { return }
            self.transcribingLine = self.state.statusLine
        }
    }

    /// Marks that the next status line is the focus monitor's.
    private func focusTargetChanged() {
        focusLinePending = true
    }

    private func insertResultChanged(_ result: InsertResult?) {
        guard captureActive, let result else { return }
        insertSucceeded = result.success
    }

    /// A late status line corrects the pill at most once (ruling R29). While
    /// the pill waits, the first different line becomes the outcome. After a
    /// neutral outcome, one later line replaces it, since that outcome IS the
    /// status line. Either way the window restarts and nothing follows after.
    /// A failed insert keeps its own message. The one line right after a
    /// focus change is ignored outright (rulings R35, R53): it neither ends
    /// the hold nor uses the follow, and it clears the mark.
    private func statusLineChanged(_ line: String) {
        if focusLinePending {
            focusLinePending = false
            return
        }
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch afterCapture {
        case .none:
            return
        case .awaitingLateStatus(let heldLine):
            guard line != heldLine,
                  let outcome = PillOutcome.classify(
                      finalState: lastState, insertSucceeded: insertSucceeded, statusLine: line)
            else { return }
            show(outcome, follows: 0)
        case .showing(let follows):
            guard follows > 0, case .status(let shown) = presentation.outcome, line != shown else { return }
            show(.status(message: line), follows: 0)
        }
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
            self.classifyOutcome()
        }
    }

    private func classifyOutcome() {
        outcomeTask = nil
        classificationPending = false
        captureActive = false
        transcribingLineTask?.cancel()
        transcribingLineTask = nil
        guard let outcome = PillOutcome.classify(
            finalState: lastState, insertSucceeded: insertSucceeded, statusLine: state.statusLine
        ) else {
            hide()
            return
        }
        if case .status(let message) = outcome, message == transcribingLine {
            awaitLateStatus(heldLine: message)
            return
        }
        show(outcome, follows: 1)
    }

    /// Keeps the working row and waits for a new status line; if none comes
    /// within `lateStatusHold`, hides with no outcome.
    private func awaitLateStatus(heldLine: String) {
        afterCapture = .awaitingLateStatus(heldLine: heldLine)
        presentation.outcome = nil
        presentation.awaitingLateStatus = true
        // The session is idle, so the row offers no cancel: nothing to click.
        panel.ignoresMouseEvents = true
        hide(after: lateStatusHold)
    }

    /// Shows `outcome`, announces it and starts its full window.
    private func show(_ outcome: PillOutcome, follows: Int) {
        afterCapture = .showing(follows: follows)
        presentation.awaitingLateStatus = false
        presentation.outcome = outcome
        announce(outcome.announcement)
        place(size: Self.pillSize(for: outcome))
        panel.ignoresMouseEvents = true
        if !panel.isVisible { panel.orderFrontRegardless() }
        hide(after: outcomeDuration)
    }

    /// Replaces any running timer. A new capture or a later state change
    /// cancels it; only a timer that ran its course hides here.
    private func hide(after duration: Duration) {
        outcomeTask?.cancel()
        outcomeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            self.outcomeTask = nil
            self.hide()
        }
    }

    // MARK: - Panel

    /// The live and working rows. The pill takes clicks only while it offers
    /// cancel (ruling R45); while inserting it offers none, so clicks pass
    /// through to the app underneath.
    private func showLive() {
        panel.ignoresMouseEvents = !RecordingPillView.offersCancel(sessionState: lastState)
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
        focusLinePending = false
        afterCapture = .none
        presentation.outcome = nil
        presentation.awaitingLateStatus = false
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}
