import SwiftUI
import AppKit

/// Captures local key events for the SwiftUI view it's attached to.
///
/// Used by the cockpit window to wire keyboard shortcuts that SwiftUI's
/// `.keyboardShortcut` modifier can't reach (e.g. capturing ⌘K to present
/// the action palette, or ⌘\ to toggle the side panel).
///
/// The handler returns `nil` to consume the event or returns the event to
/// let it propagate.
struct KeyEventBridge: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = KeyMonitorView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyMonitorView)?.handler = handler
    }

    private final class KeyMonitorView: NSView {
        var handler: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handler?(event) ?? event
                }
            } else if window == nil, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }
    }
}
