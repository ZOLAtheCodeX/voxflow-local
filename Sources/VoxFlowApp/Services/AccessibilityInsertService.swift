import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct TextInsertionPolicy: Sendable, Equatable {
    let isVerbatim: Bool
    let submits: Bool
    let capturedFocus: CapturedInsertionFocus?
    let voiceActionPermission: CapturedVoiceActions?

    static let prose = Self(isVerbatim: false, submits: false, capturedFocus: nil, voiceActionPermission: nil)
    static let verbatim = Self(isVerbatim: true, submits: false, capturedFocus: nil, voiceActionPermission: nil)

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isVerbatim == rhs.isVerbatim && lhs.submits == rhs.submits
            && lhs.capturedFocus === rhs.capturedFocus
            && lhs.voiceActionPermission === rhs.voiceActionPermission
    }

    func withSubmission(_ enabled: Bool) -> Self {
        Self(isVerbatim: isVerbatim, submits: enabled, capturedFocus: capturedFocus, voiceActionPermission: voiceActionPermission)
    }

    func withCapturedFocus(_ focus: CapturedInsertionFocus?) -> Self {
        Self(isVerbatim: isVerbatim, submits: submits, capturedFocus: focus, voiceActionPermission: voiceActionPermission)
    }

    func withVoiceActionPermission(_ permission: CapturedVoiceActions?) -> Self {
        Self(isVerbatim: isVerbatim, submits: submits, capturedFocus: capturedFocus, voiceActionPermission: permission)
    }

    func adjusted(_ text: String, precedingCharacter: Character?) -> String {
        isVerbatim ? text : SmartSpacing.adjusted(text, precedingCharacter: precedingCharacter)
    }
}

/// Seam for text insertion so unit tests can NEVER reach the real
/// accessibility machinery. The ghost-"hello" saga's final culprit:
/// TextInsertionCoordinatorTests used the real service, so every
/// `swift test` run performed genuine AX insertions of "hello" into
/// whatever app had focus on the developer's machine — for weeks.
@MainActor
protocol TextInserting {
    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult
    func insert(text: String, targetApp: NSRunningApplication?, policy: TextInsertionPolicy) async -> InsertResult
}

extension TextInserting {
    func insert(text: String, targetApp: NSRunningApplication?, policy: TextInsertionPolicy) async -> InsertResult {
        await insert(text: text, targetApp: targetApp)
    }
}

@MainActor
final class AccessibilityInsertService: TextInserting {
    private let systemWide = AXUIElementCreateSystemWide()

    /// What we last inserted, for boundary-aware spacing when AX can't read the
    /// field (Electron/web/terminals). Overwritten on every successful insert;
    /// cleared by any real user key/mouse event (see the invalidation monitor),
    /// by ``triggerUndo()``, and age-bounded by
    /// ``SmartSpacing/priorInsertionMaxAge``.
    private var priorInsertion: SmartSpacing.PriorInsertion?

    /// Global key/mouse monitor that invalidates ``priorInsertion``: the record
    /// describes a field we cannot observe, so ANY real user input (Enter sent
    /// the message, a click moved the cursor, typing edited the text) makes it
    /// untrustworthy. Installed lazily on the first record — never in tests and
    /// never before the feature has something to protect. VoxFlow's own
    /// synthetic events (the paste Cmd+V) are tagged and ignored.
    private var invalidationMonitor: Any?

    /// Marks CGEvents VoxFlow posts itself so the invalidation monitor can
    /// tell them apart from real user input. "VOXF" in ASCII.
    private static let syntheticEventTag: Int64 = 0x564F_5846

    // No deinit removing the monitor: the service is app-lifetime (a `let` on
    // AppCoordinator), and monitor removal must happen on the main thread,
    // which a nonisolated deinit cannot guarantee under strict concurrency.
    private func installInvalidationMonitorIfNeeded() {
        guard invalidationMonitor == nil,
              NSClassFromString("XCTestCase") == nil else { return }
        invalidationMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData)
                    != AccessibilityInsertService.syntheticEventTag else { return }
            Task { @MainActor [weak self] in
                self?.priorInsertion = nil
            }
        }
    }

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
    /// `.fieldStart` (cursor at position 0) is an authoritative answer, not a
    /// failure — conflating it with `.unreadable` let the prior-insertion
    /// fallback put a stray leading space at the start of fresh documents in
    /// fully AX-readable apps.
    private func precedingAXRead(targetPID: pid_t?) -> SmartSpacing.AXPrecedingRead {
        guard let focused = copyOwnedFocusedElement(targetPID: targetPID),
              let value = copyStringAttribute(kAXValueAttribute as CFString, on: focused),
              let range = copySelectedRange(on: focused) else { return .unreadable }
        if range.location == 0 { return .fieldStart }
        let ns = value as NSString
        guard range.location > 0, range.location <= ns.length else { return .unreadable }
        guard let preceding = ns.substring(with: NSRange(location: range.location - 1, length: 1)).first else {
            return .unreadable
        }
        return .character(preceding)
    }

    func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
        await insert(text: text, targetApp: targetApp, policy: .prose)
    }

    func insert(text: String, targetApp: NSRunningApplication?, policy: TextInsertionPolicy) async -> InsertResult {
        guard !Task.isCancelled, let targetApp, !targetApp.isTerminated else {
            return InsertResult(method: .failed, success: false, fallbackUsed: false,
                                errorCode: Task.isCancelled ? "CANCELLED" : "TARGET_UNAVAILABLE")
        }
        guard policy.voiceActionPermission?.revoked != true,
              policy.capturedFocus?.matchesForInsertion(targetPID: targetApp.processIdentifier) != false else {
            return InsertResult(method: .failed, success: false, fallbackUsed: false, errorCode: "TARGET_CHANGED")
        }
        // R5.0: boundary-aware spacing — successive dictations used to land
        // back-to-back ("test.I've tested"). The AX read returns nil in
        // Electron/web/terminals (the paste-fallback apps), so fall back to the
        // trailing char of our own last insertion into the same target.
        let preceding = SmartSpacing.effectivePrecedingCharacter(
            axRead: policy.isVerbatim ? .unreadable : precedingAXRead(targetPID: targetApp.processIdentifier),
            prior: priorInsertion,
            currentTargetPid: targetApp.processIdentifier
        )
        let text = policy.adjusted(text, precedingCharacter: preceding)
        // No ``?? NSWorkspace.shared.frontmostApplication`` fallback here —
        // callers must commit to a target. The frozen snapshot is the
        // source of truth for "where the user was typing"; resolving
        // frontmost at insert time is the bug the cockpit (and dictation
        // path) explicitly freeze against. The parameterless overload
        // above keeps the legacy "use frontmost" behaviour available, but
        // makes the choice explicit at the call site.
        let directFocus = policy.submits ? copyOwnedFocusedElement(targetPID: targetApp.processIdentifier) : nil
        if insertDirectly(text: text, targetPID: targetApp.processIdentifier) {
            recordPriorInsertion(text, targetApp: targetApp)
            return InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil,
                                submission: submitIfRequested(policy, targetApp: targetApp, expectedFocus: directFocus))
        }

        let paste = await simulatePaste(text: text, targetApp: targetApp, policy: policy)
        var result = Self.pasteOutcome(
            posted: paste.posted, secureInputActive: IsSecureEventInputEnabled())
        if result.success {
            recordPriorInsertion(text, targetApp: targetApp)
            result.submission = submitIfRequested(policy, targetApp: targetApp, expectedFocus: paste.focus)
        }
        return result
    }

    /// No suspension between the final focus/cancellation checks and Return.
    /// A paste has already waited for the client to consume its clipboard text.
    private func submitIfRequested(_ policy: TextInsertionPolicy, targetApp: NSRunningApplication,
                                   expectedFocus: AXUIElement?) -> InsertResult.Submission {
        guard policy.submits else { return .notRequested }
        let currentFocus = copyOwnedFocusedElement(targetPID: targetApp.processIdentifier)
        let unchanged = (expectedFocus.flatMap { expected in currentFocus.map { CFEqual(expected, $0) } } ?? false)
            && policy.capturedFocus?.matchesForSubmission(targetPID: targetApp.processIdentifier) == true
            && policy.voiceActionPermission?.revoked != true
        guard Self.maySubmit(cancelled: Task.isCancelled, targetActive: targetApp.isActive,
                             targetTerminated: targetApp.isTerminated, focusUnchanged: unchanged,
                             secureInputActive: IsSecureEventInputEnabled()) else { return .skipped }
        guard simulateKeyPress(virtualKey: 0x24, flags: []) else { return .skipped }
        // The next dictation belongs to a new prompt/line, not the old boundary.
        priorInsertion = nil
        return .enterPosted
    }

    nonisolated static func maySubmit(cancelled: Bool, targetActive: Bool, targetTerminated: Bool,
                                      focusUnchanged: Bool, secureInputActive: Bool) -> Bool {
        !cancelled && targetActive && !targetTerminated && focusUnchanged && !secureInputActive
    }

    /// Maps the paste attempt to an honest result. `posted` only proves the
    /// Cmd+V event was POSTED — under secure event input the target never
    /// receives it, so nothing landed (and the paste path restored the
    /// previous clipboard, so the text isn't there either). Reporting that
    /// as success wrote an "Inserted" receipt for text that went nowhere
    /// (session 29 review) — the exact inverse of the ghost-text bug this
    /// forensics stack exists to catch. Failure here routes the caller into
    /// its copy-to-clipboard fallback with a truthful status line.
    nonisolated static func pasteOutcome(posted: Bool, secureInputActive: Bool) -> InsertResult {
        guard posted else {
            return InsertResult(
                method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
        }
        guard !secureInputActive else {
            return InsertResult(
                method: .failed, success: false, fallbackUsed: true,
                errorCode: "SECURE_INPUT_BLOCKED")
        }
        return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
    }

    /// Remember what we just inserted so the next insertion into the same target
    /// can space correctly even when AX can't read the field. Recorded only on a
    /// successful insert — a failed attempt didn't change the field.
    private func recordPriorInsertion(_ insertedText: String, targetApp: NSRunningApplication?) {
        priorInsertion = SmartSpacing.PriorInsertion(
            targetPid: targetApp?.processIdentifier,
            trailingCharacter: insertedText.last,
            recordedAt: Date()
        )
        installInvalidationMonitorIfNeeded()
    }

    func triggerUndo() -> Bool {
        // Undo removes (some of) our text — the trailing-character record no
        // longer describes the field.
        priorInsertion = nil
        return simulateKeyPress(virtualKey: 0x06, flags: .maskCommand)
    }

    private func insertDirectly(text: String, targetPID: pid_t) -> Bool {
        guard !Task.isCancelled, let focusedElement = copyOwnedFocusedElement(targetPID: targetPID) else {
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

    private func simulatePaste(text: String, targetApp: NSRunningApplication? = nil,
                               policy: TextInsertionPolicy = .prose) async -> (posted: Bool, focus: AXUIElement?) {
        guard let targetApp, !targetApp.isTerminated, !Task.isCancelled else { return (false, nil) }
        let pasteboard = NSPasteboard.general

        // Save the user's current clipboard so we can restore it after pasting
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return (false, nil) }
        // Snapshot the pasteboard generation after OUR write. If the user
        // copies something during the paste window below, changeCount moves
        // past this value and we must NOT clobber their new clipboard with
        // the stale save (audit S4).
        let ourChangeCount = pasteboard.changeCount
        defer {
            if let previous = previousContents, pasteboard.changeCount == ourChangeCount {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        // Re-activate the target app — focus may have shifted during transcription.
        // Uses Task.sleep to yield the main thread during the wait.
        if !targetApp.isActive {
            targetApp.activate()
            // Give macOS time to bring the app window forward.
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        } else {
            // Brief delay for Electron apps to register clipboard changes before Cmd+V
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        }

        // Activation can fail, and cancellation can arrive during either wait.
        // Never post Cmd+V to the unrelated app that still owns the keyboard.
        guard !Task.isCancelled, targetApp.isActive, !targetApp.isTerminated else { return (false, nil) }
        guard policy.voiceActionPermission?.revoked != true,
              policy.capturedFocus?.matchesForInsertion(targetPID: targetApp.processIdentifier) != false else { return (false, nil) }
        let focus = policy.submits ? copyOwnedFocusedElement(targetPID: targetApp.processIdentifier) : nil
        let pasted = simulateKeyPress(virtualKey: 0x09, flags: .maskCommand)

        // Restore the user's previous clipboard after a brief delay
        // so the target app has time to process the paste event
        do {
            try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        } catch {
            // Even if cancelled, we fall through to restore
        }

        return (pasted, focus)
    }

    nonisolated static func ownsFocusedElement(targetPID: pid_t?, focusedPID: pid_t?) -> Bool {
        guard let targetPID, targetPID > 0, let focusedPID else { return false }
        return targetPID == focusedPID
    }

    private func copyOwnedFocusedElement(targetPID: pid_t?) -> AXUIElement? {
        guard let element = copyFocusedElement() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              Self.ownsFocusedElement(targetPID: targetPID, focusedPID: pid) else { return nil }
        return element
    }

    private func simulateKeyPress(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Tag our own events so the invalidation monitor ignores them —
        // otherwise the paste's Cmd+V would clear the record it just enabled.
        source.userData = Self.syntheticEventTag
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
