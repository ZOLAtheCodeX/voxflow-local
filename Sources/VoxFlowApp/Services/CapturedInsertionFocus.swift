import AppKit
import ApplicationServices

/// Shared identity policy, also exercised without creating any AX objects.
struct InsertionFocusSnapshot<Identity: Equatable> {
    let processID: pid_t
    let window: Identity?
    let field: Identity?

    func matches(_ current: Self, requireKnown: Bool) -> Bool {
        guard processID > 0, processID == current.processID else { return false }
        if requireKnown && (window == nil || field == nil) { return false }
        if let window, window != current.window { return false }
        if let field, field != current.field { return false }
        return true
    }
}

private struct AXFocusIdentity: Equatable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
}

/// Retained AX identities from capture start. All AX access stays on MainActor;
/// the actor-isolated reference can travel with an immutable workflow request.
@MainActor
final class CapturedInsertionFocus {
    private let application: AXUIElement
    private let expected: InsertionFocusSnapshot<AXFocusIdentity>
    private var submissionRevoked = false

    /// A Settings change can withdraw pending Enter without discarding text.
    func revokeSubmission() { submissionRevoked = true }

    private init(application: AXUIElement, processID: pid_t) {
        self.application = application
        expected = Self.read(application: application, processID: processID)
    }

    static func capture(for app: NSRunningApplication?) -> CapturedInsertionFocus? {
        guard let app, !app.isTerminated else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        return CapturedInsertionFocus(application: application, processID: app.processIdentifier)
    }

    /// Unknown AX identities preserve the existing text-only fallback, but
    /// cannot authorize Return. A known window/field change blocks insertion.
    func matchesForInsertion(targetPID: pid_t) -> Bool {
        expected.matches(Self.read(application: application, processID: targetPID), requireKnown: false)
    }

    func matchesForSubmission(targetPID: pid_t) -> Bool {
        !submissionRevoked && expected.matches(Self.read(application: application, processID: targetPID), requireKnown: true)
    }

    private static func read(application: AXUIElement, processID: pid_t) -> InsertionFocusSnapshot<AXFocusIdentity> {
        InsertionFocusSnapshot(processID: processID,
            window: element(kAXFocusedWindowAttribute, on: application).map(AXFocusIdentity.init),
            field: element(kAXFocusedUIElementAttribute, on: application).map(AXFocusIdentity.init))
    }

    private static func element(_ attribute: String, on application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String, role != kAXApplicationRole else { return nil }
        if attribute == kAXFocusedWindowAttribute && role != kAXWindowRole && role != kAXSheetRole { return nil }
        return element
    }
}
