import AppKit
import Foundation
import os

/// Cockpit Layer 1 — Phase E. Runs a ``WorkflowChain``'s steps sequentially,
/// threading the working text from one step into the next.
///
/// Reuses the existing seams: ``SmartActionService`` for `.action` steps and
/// ``TextInsertionCoordinating`` for `.insert` steps. It never throws — every
/// outcome (including failures) is reported via ``ChainRunResult`` so the UI
/// can surface partial progress. Stops on the first failing step.
///
/// The working text starts as the *already-captured* transcript (via
/// `currentTranscript`), so a chain without a `.capture` step (the shipped
/// "Memo" and "Action items" chains) acts on the current transcript. A
/// `.capture` step re-seeds it; there is no live mid-chain recording.
/// `frozenTarget` resolves the app the user was dictating into (sourced from
/// the cockpit session, reconstructed from the frozen pid), so an insert lands
/// in that app, not the cockpit window.
@MainActor
final class ChainExecutor {
    enum ChainError: Error, Equatable {
        case noTranscript
        case actionFailed(String)
        case insertFailed
        case appStepFailed(String)
        /// The cockpit session changed while the chain ran, so its text
        /// belongs to a session whose target is no longer the current one.
        case sessionChanged
    }

    struct ChainRunResult: Equatable {
        let completedSteps: Int
        let finalText: String
        let failedStepIndex: Int?
        let error: ChainError?
        let clipboardFallback: Bool
    }

    private let actionService: SmartActionService
    private let textInsertion: TextInsertionCoordinating
    private let currentTranscript: @MainActor () -> String?
    private let frozenTarget: @MainActor () -> NSRunningApplication?
    private let currentSessionID: @MainActor () -> UUID?
    private let log = Logger(subsystem: "local.voxflow.app", category: "ChainExecutor")

    init(
        actionService: SmartActionService,
        textInsertion: TextInsertionCoordinating,
        currentTranscript: @escaping @MainActor () -> String?,
        frozenTarget: @escaping @MainActor () -> NSRunningApplication?,
        currentSessionID: @escaping @MainActor () -> UUID? = { nil },
        performAppStep: (@MainActor (ChainStep) -> Bool)? = nil
    ) {
        self.actionService = actionService
        self.textInsertion = textInsertion
        self.currentTranscript = currentTranscript
        self.frozenTarget = frozenTarget
        self.currentSessionID = currentSessionID
        self.performAppStep = performAppStep
    }

    /// R5.6: dispatches app-level steps (.setMode/.setTone/.openWindow) to
    /// the coordinator. Returns false to stop the chain.
    private let performAppStep: (@MainActor (ChainStep) -> Bool)?

    func run(_ chain: WorkflowChain) async -> ChainRunResult {
        // The run is bound to the session it started on: its text and its
        // target both come from that session.
        let originSession = currentSessionID()
        var workingText = currentTranscript() ?? ""
        log.info("running chain '\(chain.name)' (\(chain.steps.count) steps)")

        for (index, step) in chain.steps.enumerated() {
            switch step {
            case .capture:
                // Seed from the already-captured transcript — no live recording.
                guard let transcript = currentTranscript(), !transcript.isEmpty else {
                    return failure(.noTranscript, atIndex: index, workingText: workingText, clipboardFallback: false)
                }
                workingText = transcript

            case .action(let actionId):
                // Never send a request for nothing to act on.
                guard !workingText.isEmpty else {
                    return failure(.noTranscript, atIndex: index, workingText: workingText, clipboardFallback: false)
                }
                do {
                    let result = try await actionService.apply(actionId, to: workingText)
                    if let error = result.error {
                        return failure(.actionFailed(error), atIndex: index, workingText: workingText, clipboardFallback: false)
                    }
                    // guardrailTriggered does NOT stop — the fallback output passes through.
                    workingText = result.output
                } catch {
                    return failure(.actionFailed(error.localizedDescription), atIndex: index, workingText: workingText, clipboardFallback: false)
                }

            case .setMode, .setTone, .openWindow:
                guard let performAppStep, performAppStep(step) else {
                    return failure(
                        .appStepFailed(step.summary), atIndex: index,
                        workingText: workingText, clipboardFallback: false)
                }

            case .insert:
                // An action await can outlive the session (inserted or reset,
                // then a new one started); its target is not this text's.
                guard currentSessionID() == originSession else {
                    return failure(.sessionChanged, atIndex: index, workingText: workingText, clipboardFallback: false)
                }
                let ok = await textInsertion.insertText(
                    workingText, statusSuffix: "Chain: \(chain.name)", targetApp: frozenTarget())
                if !ok {
                    // The real coordinator only clipboard-copies non-empty text:
                    // an empty insert returns false BEFORE the fallback branch,
                    // so nothing lands on the clipboard. Report honestly.
                    return failure(
                        .insertFailed, atIndex: index, workingText: workingText,
                        clipboardFallback: !workingText.isEmpty)
                }
            }
        }

        return ChainRunResult(
            completedSteps: chain.steps.count,
            finalText: workingText,
            failedStepIndex: nil,
            error: nil,
            clipboardFallback: false)
    }

    /// Build a stop result. `completedSteps` is the count of steps that fully
    /// succeeded before the failing one — which equals the failing index.
    private func failure(
        _ error: ChainError, atIndex index: Int, workingText: String, clipboardFallback: Bool
    ) -> ChainRunResult {
        log.error("chain stopped at step \(index): \(String(describing: error))")
        return ChainRunResult(
            completedSteps: index,
            finalText: workingText,
            failedStepIndex: index,
            error: error,
            clipboardFallback: clipboardFallback)
    }
}
