import AppKit
import Foundation
import os.log

@MainActor protocol TextInsertionCoordinating {
    func insertCurrentText()
    func insertCurrentText(targetApp: NSRunningApplication?)
    func insertText(_ text: String, statusSuffix: String) -> Bool
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) -> Bool
    func copyCurrentText()
    func copyMeetingMarkdownTemplate()
    func copyMeetingNotionTemplate()
}

@MainActor
final class TextInsertionCoordinator: TextInsertionCoordinating {
    private let log = Logger(subsystem: "local.voxflow.app", category: "TextInsertion")
    private let state: AppState
    private let insertService: AccessibilityInsertService

    init(state: AppState, insertService: AccessibilityInsertService) {
        self.state = state
        self.insertService = insertService
    }

    func insertCurrentText() {
        insertCurrentText(targetApp: nil)
    }

    func insertCurrentText(targetApp: NSRunningApplication?) {
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
        let result = insertService.insert(text: state.displayText, targetApp: targetApp)
        log.info("insertCurrentText: method=\(String(describing: result.method)), success=\(result.success), fallback=\(result.fallbackUsed), app=\(appName)")
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
    func insertText(_ text: String, statusSuffix: String) -> Bool {
        insertText(text, statusSuffix: statusSuffix, targetApp: nil)
    }

    @discardableResult
    func insertText(_ text: String, statusSuffix: String, targetApp: NSRunningApplication?) -> Bool {
        guard !text.isEmpty else { return false }

        let appName = state.focusTarget.appName ?? "Unknown App"
        let result = insertService.insert(text: text, targetApp: targetApp)
        log.info("insertText: method=\(String(describing: result.method)), success=\(result.success), fallback=\(result.fallbackUsed), app=\(appName)")
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
