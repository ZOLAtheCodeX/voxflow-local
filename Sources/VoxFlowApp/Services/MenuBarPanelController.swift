import AppKit
import SwiftUI
import Combine
import os.log

@MainActor
final class MenuBarPanelController {
    private let log = Logger(subsystem: "local.voxflow.app", category: "MenuBarPanel")

    // nonisolated(unsafe) allows deinit cleanup in Swift 6.2 strict concurrency.
    // These are only mutated from @MainActor context; the annotation is solely
    // to satisfy the nonisolated deinit access requirement.
    private nonisolated(unsafe) let statusItem: NSStatusItem
    private let panel: NSPanel
    private nonisolated(unsafe) var globalClickMonitor: Any?
    private nonisolated(unsafe) var localClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    var isOpen: Bool { panel.isVisible }

    init<Content: View>(content: Content, iconName: String = "mic.fill") {
        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: iconName, accessibilityDescription: "VoxFlow")
        }

        // Non-activating panel
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 600),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = true
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView

        self.panel = panel

        // Wire up status item click action
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
    }

    func updateIcon(systemName: String) {
        statusItem.button?.image = NSImage(
            systemSymbolName: systemName,
            accessibilityDescription: "VoxFlow"
        )
    }

    func toggle() {
        if panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        guard let button = statusItem.button else { return }
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let panelWidth = panel.frame.width
        let x = buttonRect.midX - panelWidth / 2
        let y = buttonRect.minY - panel.frame.height - 4
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()

        installClickMonitors()
        log.debug("Panel opened")
    }

    func close() {
        panel.orderOut(nil)
        removeClickMonitors()
        log.debug("Panel closed")
    }

    private func installClickMonitors() {
        // Close on click outside the panel
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // NSEvent monitors fire on the main thread; assert isolation
            MainActor.assumeIsolated {
                self?.close()
            }
        }

        // Close on click on status item while open
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            // NSEvent monitors fire on the main thread; assert isolation
            MainActor.assumeIsolated {
                if let self,
                   let window = event.window,
                   window != self.panel,
                   window == self.statusItem.button?.window {
                    self.close()
                }
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggle()
    }

    deinit {
        // deinit is nonisolated in Swift 6.2 — access stored properties directly
        // without calling @MainActor-isolated methods. NSEvent.removeMonitor and
        // NSStatusBar.removeStatusItem are thread-safe for cleanup purposes.
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSStatusBar.system.removeStatusItem(statusItem)
    }
}
