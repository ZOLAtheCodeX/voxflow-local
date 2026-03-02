import AppKit
import SwiftUI
import Combine
import os.log

private enum VFPanel {
    static let cornerRadius: CGFloat = 12
}

@MainActor
final class MenuBarPanelController {
    private let log = Logger(subsystem: "local.voxflow.app", category: "MenuBarPanel")

    // nonisolated(unsafe) allows deinit cleanup in Swift 6.2 strict concurrency.
    // These are only mutated from @MainActor context; the annotation is solely
    // to satisfy the nonisolated deinit access requirement.
    private nonisolated(unsafe) var statusItem: NSStatusItem
    private let panel: NSPanel
    private nonisolated(unsafe) var globalClickMonitor: Any?
    private nonisolated(unsafe) var localClickMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var currentIconName: String

    // Explicit symbol configuration for menu bar icons.
    // NSImage(systemSymbolName:) without a configuration has no font metric
    // context in NSStatusBarButton, producing an image that registers a frame
    // but renders transparent. A fixed scale forces deterministic rendering.
    private static let symbolConfig = NSImage.SymbolConfiguration(scale: .medium)

    var isOpen: Bool { panel.isVisible }

    init<Content: View>(content: Content, iconName: String = "mic.fill") {
        // Status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.currentIconName = iconName

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
        panel.appearance = NSApp.effectiveAppearance
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: content)
        hostingView.layer?.cornerRadius = VFPanel.cornerRadius
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView

        self.panel = panel

        // Wire up status item button with icon and click action
        configureStatusItemButton(iconName: iconName)
    }

    private func configureStatusItemButton(iconName: String) {
        if let button = statusItem.button {
            if let image = menuBarImage(named: iconName) {
                button.image = image
                log.info("Menu bar icon set: \(iconName)")
            } else if let fallback = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "VoxFlow") {
                fallback.isTemplate = true
                button.image = fallback
                log.warning("Primary icon '\(iconName)' failed; using unconfigured mic.fill fallback")
            } else {
                button.title = "VF"
                log.warning("All icon fallbacks failed; using text-only 'VF' title")
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }
    }

    func updateIcon(systemName: String) {
        currentIconName = systemName
        statusItem.button?.image = menuBarImage(named: systemName)
    }

    private func menuBarImage(named symbolName: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoxFlow")?
            .withSymbolConfiguration(Self.symbolConfig) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Re-register the status item with NSStatusBar after an activation policy change.
    /// The old item's menu bar slot may have been invalidated by a
    /// `.accessory` -> `.regular` -> `.accessory` policy round-trip.
    func refreshStatusItem() {
        let wasOpen = panel.isVisible

        // Tear down old item
        removeClickMonitors()
        NSStatusBar.system.removeStatusItem(statusItem)

        // Create fresh item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemButton(iconName: currentIconName)

        // Restore panel state
        if wasOpen {
            open()
        }

        log.debug("Status item refreshed")
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
