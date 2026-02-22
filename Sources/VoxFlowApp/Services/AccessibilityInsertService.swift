import AppKit
import ApplicationServices
import Foundation

final class AccessibilityInsertService {
    private let systemWide = AXUIElementCreateSystemWide()

    func focusedTargetSnapshot() -> FocusTargetSnapshot {
        guard let focusedElement = copyFocusedElement() else {
            return .unavailable
        }

        let role = copyStringAttribute(kAXRoleAttribute as CFString, on: focusedElement)
        let (appName, bundleID) = focusedAppInfo(for: focusedElement)

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
            role: role
        )
    }

    func insert(text: String) -> InsertResult {
        // Capture the target app BEFORE any insertion attempt.
        // During async transcription, focus may have shifted away.
        let targetApp = NSWorkspace.shared.frontmostApplication

        if insertDirectly(text: text) {
            return InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
        }

        if simulatePaste(text: text, targetApp: targetApp) {
            return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        }

        return InsertResult(method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
    }

    func triggerUndo() -> Bool {
        simulateKeyPress(virtualKey: 0x06, flags: .maskCommand)
    }

    private func insertDirectly(text: String) -> Bool {
        guard let focusedElement = copyFocusedElement() else {
            return false
        }

        guard let currentValue = copyStringAttribute(kAXValueAttribute as CFString, on: focusedElement) else {
            return false
        }

        guard let selectedRange = copySelectedRange(on: focusedElement) else {
            return false
        }

        let nsString = currentValue as NSString
        guard selectedRange.location <= nsString.length,
              selectedRange.location + selectedRange.length <= nsString.length else {
            return false
        }

        let updated = nsString.replacingCharacters(in: selectedRange, with: text)
        let setResult = AXUIElementSetAttributeValue(focusedElement, kAXValueAttribute as CFString, updated as CFTypeRef)
        guard setResult == .success else {
            return false
        }

        var newRange = CFRange(location: selectedRange.location + (text as NSString).length, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &newRange) else {
            return false
        }

        let cursorResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextRangeAttribute as CFString, axRange)
        return cursorResult == .success
    }

    private func simulatePaste(text: String, targetApp: NSRunningApplication? = nil) -> Bool {
        let pasteboard = NSPasteboard.general

        // Save the user's current clipboard so we can restore it after pasting
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        // Re-activate the target app — focus may have shifted during transcription
        if let app = targetApp, !app.isActive {
            app.activate()
            // Give macOS time to bring the app window forward
            usleep(150_000) // 150ms
        } else {
            // Small delay even without activation — Electron apps need time
            // to register clipboard changes before Cmd+V arrives
            usleep(50_000) // 50ms
        }

        let pasted = simulateKeyPress(virtualKey: 0x09, flags: .maskCommand)

        // Restore the user's previous clipboard after a brief delay
        // so the target app has time to process the paste event
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
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

    private func focusedAppInfo(for element: AXUIElement) -> (name: String?, bundleID: String?) {
        var pid: pid_t = 0
        let pidResult = AXUIElementGetPid(element, &pid)
        let app: NSRunningApplication?
        if pidResult == .success {
            app = NSRunningApplication(processIdentifier: pid)
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        return (app?.localizedName, app?.bundleIdentifier)
    }
}
