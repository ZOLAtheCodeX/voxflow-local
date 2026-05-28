import Foundation
import os
import SwiftUI
import AppKit

/// Cockpit Layer 0 — orchestrates the long-form workspace window.
///
/// Owns:
///   - Visibility toggle (`open()` / `close()`)
///   - Smart-action dispatch routing (`applyAction`)
///   - MRU chip ordering + promotion threshold logic
///   - Voice-command handling (only fires during the reviewing state)
///   - Undo / insert / copy / clear keyboard-shortcut targets
@MainActor
final class CockpitCoordinator: ObservableObject {
    private let state: AppState
    let sessionService: LongFormSessionService
    let actionService: SmartActionService
    private let textInsertionCoordinator: TextInsertionCoordinator?
    private let log = Logger(subsystem: "local.voxflow.app", category: "CockpitCoordinator")

    // MARK: - Notion target state (Phase C)

    /// Currently selected Notion page target. When non-nil, ⌘↩ appends to
    /// Notion instead of performing an AX insert.
    @Published var notionTarget: NotionTarget?
    @Published var notionSearchError: String?

    /// Chip promotion threshold — an action becomes a visible chip after
    /// it has been invoked this many times.
    private static let promotionThreshold = 3
    /// MRU reorder activation — after this many *total* invocations, the
    /// chip row sorts by usage frequency. Below the threshold the default
    /// order (memo / MECE / items) wins.
    private static let mruActivationThreshold = 30
    /// Voice prompt strip dismisses automatically after this many captures.
    private static let voicePromptStripDismissThreshold = 10

    init(
        state: AppState,
        sessionService: LongFormSessionService,
        actionService: SmartActionService,
        textInsertionCoordinator: TextInsertionCoordinator? = nil
    ) {
        self.state = state
        self.sessionService = sessionService
        self.actionService = actionService
        self.textInsertionCoordinator = textInsertionCoordinator
    }

    // MARK: - Window lifecycle

    func open() {
        state.cockpitVisible = true
        log.info("cockpit opened")
    }

    func close() {
        state.cockpitVisible = false
        log.info("cockpit closed")
    }

    // MARK: - Smart-action dispatch

    func applyAction(_ action: SmartActionId, to transcript: String) async throws -> SmartActionResult {
        let result = try await actionService.apply(action, to: transcript)
        state.chipInvocationCounts[action, default: 0] += 1
        state.persistChipInvocationCounts()
        promoteIfNeeded(action)
        // Mirror SmartActionService's undo-stack filter on the session
        // history: guardrail trips and unchanged echoes aren't real
        // transformations, so they don't belong in appliedActions either —
        // otherwise the JSON history shows entries ⌘Z can't undo.
        let isMeaningful = !result.guardrailTriggered
            && !result.output.isEmpty
            && result.output != transcript
        if sessionService.currentSession != nil, isMeaningful {
            sessionService.recordAppliedAction(
                AppliedAction(
                    actionId: action,
                    appliedAt: Date(),
                    beforeText: transcript,
                    afterText: result.output
                )
            )
        }
        if totalInvocations() >= Self.mruActivationThreshold {
            recomputeChipMRU()
        }
        return result
    }

    // MARK: - Voice commands (only during review state)

    func handleVoiceUtterance(_ raw: String) async throws {
        guard sessionService.state == .reviewing else { return }
        switch VoiceCommandRouter.parse(raw) {
        case .none: return
        case .action(let id):
            guard let transcript = sessionService.currentSession?.transcript else { return }
            _ = try await applyAction(id, to: transcript)
        case .undo: await undoLastAction()
        case .cancel: sessionService.reset()
        case .insert: await insertIntoTarget()
        case .copy: copyToClipboard()
        }
    }

    // MARK: - Keyboard-shortcut targets

    func undoLastAction() async {
        if let (_, beforeText) = await actionService.popLast() {
            sessionService.setTranscript(beforeText)
        }
    }

    func insertIntoTarget() async {
        guard let session = sessionService.currentSession else { return }
        let text = session.transcript
        guard !text.isEmpty else { return }

        // Phase C — Notion append branch: fires when a Notion page target is selected.
        if let target = notionTarget {
            guard let token = KeychainService.load(account: NotionKeychain.account),
                  !token.isEmpty else {
                state.statusLine = "Notion token missing — add it in Settings"
                return
            }
            do {
                _ = try await BackendAPIClient.notionAppend(pageId: target.id, text: text, token: token)
                state.statusLine = "Appended to Notion · \(target.title)"
                state.cockpitVisible = false
                sessionService.reset()
            } catch {
                state.statusLine = "Notion append failed: \(error.localizedDescription)"
            }
            return
        }

        // Existing AX-insert path — preserved verbatim.
        guard let insertionCoordinator = textInsertionCoordinator else { return }
        // Reconstruct NSRunningApplication from the pid frozen at
        // session-start. Required because at insert time the frontmost
        // app *is* the cockpit window itself — resolving via
        // NSWorkspace.shared.frontmostApplication would target the
        // cockpit, not the app the user was dictating into.
        let targetApp: NSRunningApplication? = session.targetApp?.processIdentifier
            .flatMap { NSRunningApplication(processIdentifier: $0) }
        _ = await insertionCoordinator.insertText(text, statusSuffix: "cockpit", targetApp: targetApp)
        state.cockpitVisible = false
        sessionService.reset()
    }

    func copyToClipboard() {
        guard let text = sessionService.currentSession?.transcript else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Capture lifecycle hooks (called by CockpitWindowView on stop)

    /// Called when a long-form capture transitions into reviewing state.
    /// Bumps the persisted capture count so the teaching-mode voice prompt
    /// strip eventually auto-dismisses.
    func didEnterReviewState() {
        state.totalCaptureCount += 1
        UserDefaults.standard.set(state.totalCaptureCount, forKey: "VoxFlow.totalCaptureCount")
        if state.totalCaptureCount >= Self.voicePromptStripDismissThreshold {
            state.voicePromptStripDismissed = true
            UserDefaults.standard.set(true, forKey: "VoxFlow.voicePromptStripDismissed")
        }
    }

    // MARK: - Notion search + target selection (Phase C)

    /// Search the user's Notion workspace. Loads the token from the Keychain.
    /// Sets ``notionSearchError`` (and returns []) when the token is absent or
    /// the request fails, so the side panel can surface *why* no results appeared
    /// (e.g. a wrong token) instead of looking like "no matching pages".
    func searchNotion(_ query: String) async -> [NotionTarget] {
        guard let token = KeychainService.load(account: NotionKeychain.account),
              !token.isEmpty else {
            notionSearchError = "Add your Notion token in Settings"
            return []
        }
        do {
            let results = try await BackendAPIClient.notionSearch(query: query, token: token)
            notionSearchError = nil
            return results
        } catch {
            notionSearchError = "Notion search failed: \(error.localizedDescription)"
            return []
        }
    }

    func selectNotionTarget(_ target: NotionTarget?) {
        notionTarget = target
    }

    // MARK: - MRU + promotion logic

    private func totalInvocations() -> Int {
        state.chipInvocationCounts.values.reduce(0, +)
    }

    private func promoteIfNeeded(_ action: SmartActionId) {
        guard !state.chipMRU.contains(action) else { return }
        let count = state.chipInvocationCounts[action] ?? 0
        if count >= Self.promotionThreshold {
            state.chipMRU.append(action)
            state.persistChipMRU()
        }
    }

    private func recomputeChipMRU() {
        let sorted = state.chipInvocationCounts
            .sorted { $0.value > $1.value }
            .map(\.key)
        let known = Set(sorted)
        // Preserve any default-set actions that haven't been used yet.
        let extras = state.chipMRU.filter { !known.contains($0) }
        state.chipMRU = Array((sorted + extras).prefix(6))
        state.persistChipMRU()
    }
}
