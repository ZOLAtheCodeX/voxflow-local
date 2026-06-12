import AppKit
import Foundation
import os.log

@MainActor protocol TextInsertionCoordinating {
    func insertCurrentText() async
    func insertCurrentText(targetApp: NSRunningApplication?) async
    func insertText(_ text: String, statusSuffix: String) async -> Bool
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) async -> Bool
    func copyCurrentText()
    func copyMeetingMarkdownTemplate()
    func copyMeetingNotionTemplate()
}

@MainActor
final class TextInsertionCoordinator: TextInsertionCoordinating {
    private let log = Logger(subsystem: "local.voxflow.app", category: "TextInsertion")
    private let state: AppState
    private let insertService: TextInserting

    /// Ghost-text forensics: every insertion gets a local JSONL receipt.
    private let audit: InsertionAuditLog

    init(state: AppState, insertService: TextInserting, audit: InsertionAuditLog? = nil) {
        self.state = state
        self.insertService = insertService
        self.audit = audit ?? InsertionAuditLog()
    }

    func insertCurrentText() async {
        await insertCurrentText(targetApp: nil)
    }

    func insertCurrentText(targetApp: NSRunningApplication?) async {
        guard !state.displayText.isEmpty else { return }

        if state.privacyPreview != nil {
            state.statusLine = "Approve privacy review before inserting"
            return
        }

        if state.requiresTranslationApproval && state.translationCandidate?.approved != true {
            state.statusLine = "Approve translation before inserting"
            return
        }

        if state.requiresMeetingApproval && state.meetingCandidate?.approved != true {
            state.statusLine = "Approve meeting notes before inserting"
            return
        }

        state.sessionState = .inserting
        let appName = state.focusTarget.appName ?? "Unknown App"
        let started = ContinuousClock.now
        let result = await insertService.insert(text: state.displayText, targetApp: targetApp)
        let elapsedMs = started.elapsedMilliseconds()
        log.info("insertCurrentText: duration=\(elapsedMs)ms, method=\(String(describing: result.method)), success=\(result.success), fallback=\(result.fallbackUsed), app=\(appName)")
        state.lastInsertResult = result
        recordInsertStats(forApp: appName, result: result)

        if result.success {
            state.successfulInsertCount += 1
            if result.fallbackUsed {
                state.fallbackInsertCount += 1
            }
            if result.method != .simulatedPaste {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.displayText, forType: .string)
            }
            state.statusLine = "Inserted"
            state.lastInsertedText = state.displayText
            state.sessionState = .idle
        } else {
            state.failedInsertCount += 1
            state.statusLine = "Insert failed. Copied to clipboard."
            copyCurrentText()
            state.sessionState = .review
        }
    }

    @discardableResult
    func insertText(_ text: String, statusSuffix: String) async -> Bool {
        await insertText(text, statusSuffix: statusSuffix, targetApp: nil)
    }

    @discardableResult
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) async -> Bool {
        guard !text.isEmpty else { return false }

        let appName = state.focusTarget.appName ?? "Unknown App"
        let started = ContinuousClock.now
        let result = await insertService.insert(text: text, targetApp: targetApp)
        let elapsedMs = started.elapsedMilliseconds()
        log.info("insertText: duration=\(elapsedMs)ms, method=\(String(describing: result.method)), success=\(result.success), fallback=\(result.fallbackUsed), app=\(appName)")
        state.lastInsertResult = result
        recordInsertStats(forApp: appName, result: result)

        if result.success {
            state.successfulInsertCount += 1
            if result.fallbackUsed {
                state.fallbackInsertCount += 1
            }
            if result.method != .simulatedPaste {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            state.statusLine = statusSuffix
            state.lastInsertedText = text
            audit.recordInsertion(
                text: text,
                targetApp: targetApp?.localizedName ?? appName,
                source: statusSuffix,
                confidence: state.transcriptCandidate?.confidence
            )
            return true
        } else {
            state.failedInsertCount += 1
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            state.statusLine = "Auto-insert failed — copied to clipboard"
            return false
        }
    }

    func copyCurrentText() {
        guard !state.displayText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.displayText, forType: .string)
        state.statusLine = "Copied to clipboard"
    }

    func copyMeetingMarkdownTemplate() {
        guard let meeting = state.meetingCandidate else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdownTemplate, forType: .string)
        state.statusLine = "Meeting Markdown template copied"
    }

    func copyMeetingNotionTemplate() {
        guard let meeting = state.meetingCandidate else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.notionTemplate, forType: .string)
        state.statusLine = "Meeting Notion template copied"
    }

    private func recordInsertStats(forApp appName: String, result: InsertResult) {
        var stats = state.insertStatsByApp[appName] ?? AppInsertStats(
            appName: appName,
            successCount: 0,
            fallbackCount: 0,
            failedCount: 0
        )

        if result.success {
            stats.successCount += 1
            if result.fallbackUsed {
                stats.fallbackCount += 1
            }
        } else {
            stats.failedCount += 1
        }

        state.insertStatsByApp[appName] = stats
    }
}
