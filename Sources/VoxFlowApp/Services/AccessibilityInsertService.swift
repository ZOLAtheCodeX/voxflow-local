import AppKit
import ApplicationServices
import Foundation

/// Seam for text insertion so unit tests can NEVER reach the real
/// accessibility machinery. The ghost-"hello" saga's final culprit:
/// TextInsertionCoordinatorTests used the real service, so every
/// `swift test` run performed genuine AX insertions of "hello" into
/// whatever app had focus on the developer's machine — for weeks.
@MainActor
protocol TextInserting {
    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult
}

@MainActor
final class AccessibilityInsertService: TextInserting {
    private let systemWide = AXUIElementCreateSystemWide()

    /// What we last inserted, for boundary-aware spacing when AX can't read the
    /// field (Electron/web/terminals). Overwritten on every successful insert.
    private var priorInsertion: SmartSpacing.PriorInsertion?

    func focusedTargetSnapshot() -> FocusTargetSnapshot {
        guard let focusedElement = copyFocusedElement() else {
            return .unavailable
        }

        let role = copyStringAttribute(kAXRoleAttribute as CFString, on: focusedElement)
        let (appName, bundleID, pid) = focusedAppInfo(for: focusedElement)

        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            "AXSearchField",
            kAXComboBoxRole as String,
            "AXEditableTextArea"
        ]

        let isTextInput = role.map { textRoles.contains($0) } ?? false
        let hasCursor = hasInsertionCursor(on: focusedElement)

        return FocusTargetSnapshot(
            hasFocusedTextInput: isTextInput,
            hasInsertionCursor: hasCursor,
            appName: appName,
            bundleID: bundleID,
            role: role,
            processIdentifier: pid
        )
    }

    /// Convenience overload that explicitly captures the frontmost app at
    /// call time. Use this only when there is no frozen target snapshot to
    /// thread through — the cockpit and dictation paths both have one and
    /// must pass it via ``insert(text:targetApp:)`` so AX targets the
    /// intended app and not the cockpit / menu-bar panel.
    func insert(text: String) async -> InsertResult {
        await insert(text: text, targetApp: NSWorkspace.shared.frontmostApplication)
    }

    /// Character immediately before the insertion point, read via AX.
    /// nil when the field is empty, unreadable, or has a selection start at 0.
    private func precedingCharacter() -> Character? {
        guard let focused = copyFocusedElement(),
              let value = copyStringAttribute(kAXValueAttribute as CFString, on: focused),
              let range = copySelectedRange(on: focused),
              range.location > 0 else { return nil }
        let ns = value as NSString
        guard range.location <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: range.location - 1, length: 1)).first
    }

    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
        // R5.0: boundary-aware spacing — successive dictations used to land
        // back-to-back ("test.I've tested"). The AX read returns nil in
        // Electron/web/terminals (the paste-fallback apps), so fall back to the
        // trailing char of our own last insertion into the same target.
        let preceding = SmartSpacing.effectivePrecedingCharacter(
            axPreceding: precedingCharacter(),
            prior: priorInsertion,
            currentTargetPid: targetApp?.processIdentifier
        )
        let text = SmartSpacing.adjusted(text, precedingCharacter: preceding)
        // No ``?? NSWorkspace.shared.frontmostApplication`` fallback here —
        // callers must commit to a target. The frozen snapshot is the
        // source of truth for "where the user was typing"; resolving
        // frontmost at insert time is the bug the cockpit (and dictation
        // path) explicitly freeze against. The parameterless overload
        // above keeps the legacy "use frontmost" behaviour available, but
        // makes the choice explicit at the call site.
        if insertDirectly(text: text) {
            recordPriorInsertion(text, targetApp: targetApp)
            return InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
        }

        if await simulatePaste(text: text, targetApp: targetApp) {
            recordPriorInsertion(text, targetApp: targetApp)
            return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        }

        return InsertResult(method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
    }

    /// Remember what we just inserted so the next insertion into the same target
    /// can space correctly even when AX can't read the field. Recorded only on a
    /// successful insert — a failed attempt didn't change the field.
    private func recordPriorInsertion(_ insertedText: String, targetApp: NSRunningApplication?) {
        priorInsertion = SmartSpacing.PriorInsertion(
            targetPid: targetApp?.processIdentifier,
            trailingCharacter: insertedText.last
        )
    }

    func triggerUndo() -> Bool {
        simulateKeyPress(virtualKey: 0x06, flags: .maskCommand)
    }

    private func insertDirectly(text: String) -> Bool {
        guard let focusedElement = copyFocusedElement() else {
            return false
        }

        // Snapshot the field value before any insertion attempt so we can
        // verify the AX call actually had an effect — some apps return
        // .success from kAXSelectedTextAttribute without changing content.
        let valueBefore = copyStringAttribute(kAXValueAttribute as CFString, on: focusedElement)

        // Prefer kAXSelectedTextAttribute — inserts at cursor position without
        // touching surrounding content or stripping rich text formatting.
        let selectedTextResult = AXUIElementSetAttributeValue(
            focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if selectedTextResult == .success {
            let valueAfter = copyStringAttribute(kAXValueAttribute as CFString, on: focusedElement)
            if valueAfter != valueBefore, let valueAfter, valueAfter.contains(text) {
                return true
            }
            // AX returned success but content didn't change — fall through to paste
        }

        return false
    }

    private func simulatePaste(text: String, targetApp: NSRunningApplication? = nil) async -> Bool {
        let pasteboard = NSPasteboard.general

        // Save the user's current clipboard so we can restore it after pasting
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        // Snapshot the pasteboard generation after OUR write. If the user
        // copies something during the paste window below, changeCount moves
        // past this value and we must NOT clobber their new clipboard with
        // the stale save (audit S4).
        let ourChangeCount = pasteboard.changeCount

        // Re-activate the target app — focus may have shifted during transcription.
        // Uses Task.sleep to yield the main thread during the wait.
        if let app = targetApp, !app.isActive {
            app.activate()
            // Give macOS time to bring the app window forward.
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        } else {
            // Brief delay for Electron apps to register clipboard changes before Cmd+V
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }

        let pasted = simulateKeyPress(virtualKey: 0x09, flags: .maskCommand)

        // Restore the user's previous clipboard after a brief delay
        // so the target app has time to process the paste event
        do {
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        } catch {
            // Even if cancelled, we fall through to restore
        }

        if let previous = previousContents, pasteboard.changeCount == ourChangeCount {
            pasteboard.clearContents()
            pasteboard.setString(previous, forType: .string)
        }

        return pasted
    }

    private func simulateKeyPress(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false) else {
            return false
        }

        cmdDown.flags = flags
        cmdUp.flags = flags
        cmdDown.post(tap: .cghidEventTap)
        cmdUp.post(tap: .cghidEventTap)
        return true
    }

    private func copyFocusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copySelectedRange(on element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }

        return NSRange(location: range.location, length: range.length)
    }

    private func hasInsertionCursor(on element: AXUIElement) -> Bool {
        guard let range = copySelectedRange(on: element) else {
            return false
        }

        return range.length == 0 && range.location >= 0
    }

    private func focusedAppInfo(for element: AXUIElement) -> (name: String?, bundleID: String?, pid: Int32?) {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        let app: NSRunningApplication?
        let resolvedPid: Int32?
        if pidResult == .success {
            app = NSRunningApplication(processIdentifier: pid)
            resolvedPid = pid
        } else {
            app = NSWorkspace.shared.frontmostApplication
            resolvedPid = app?.processIdentifier
        }
        return (app?.localizedName, app?.bundleIdentifier, resolvedPid)
    }
}
