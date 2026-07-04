import AppKit

/// What the cockpit window should do with a key event.
enum CockpitKeyAction: Equatable {
    case record            // ⌘R — start long-form capture
    case stop              // ⌘. — stop capture
    case undo              // ⌘Z — undo last smart action
    case insert            // ⌘↩ — insert into target + close + reset
    case copy              // ⌘C — copy whole transcript
    case toggleSidePanel   // ⌘\
    case close             // ⌘W / esc
    case exitEditing       // esc while a text view is focused — resign focus (commits the edit)
    case passThrough       // not ours — let AppKit/SwiftUI handle it
}

/// Pure keypress → action policy for the cockpit's global key monitor.
///
/// The monitor (``KeyEventBridge``) sees events BEFORE SwiftUI focus routing,
/// so without the `isTextEditingActive` gate it hijacked native editing:
/// ⌘Z undid the last smart action instead of the text edit, ⌘C copied the
/// whole transcript instead of the selection, and esc closed the window
/// mid-edit. While an editable text view is first responder (the transcript
/// editor in `.reviewing`, or the Notion search field), ⌘Z/⌘C pass through
/// to the native responder chain and esc exits editing — a second esc, no
/// longer editing, closes. Capture/insert/window shortcuts stay global in
/// both states.
enum CockpitKeyRouter {
    private static let escKeyCode: UInt16 = 53

    static func route(
        key: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isTextEditingActive: Bool
    ) -> CockpitKeyAction {
        if modifiers == .command {
            switch key {
            case "r": return .record
            case ".": return .stop
            case "z": return isTextEditingActive ? .passThrough : .undo
            case "\r": return .insert
            case "c": return isTextEditingActive ? .passThrough : .copy
            case "\\": return .toggleSidePanel
            case "w": return .close
            default: return .passThrough
            }
        }
        if keyCode == escKeyCode {
            return isTextEditingActive ? .exitEditing : .close
        }
        return .passThrough
    }
}
