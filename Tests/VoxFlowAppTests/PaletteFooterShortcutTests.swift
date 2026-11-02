import AppKit
import SwiftUI
import XCTest
@testable import VoxFlowApp

/// The palette footer keeps its shortcuts after the refresh: Cmd-1 opens
/// Setup through a button that is invisible and hidden from VoiceOver, Cmd-2
/// opens the Dashboard, Cmd-Q quits. The footer is hosted in a borderless
/// window that is never ordered front, with recorder closures: no
/// coordinator, no Settings scene, no real quit.
@MainActor
final class PaletteFooterShortcutTests: XCTestCase {

    private final class Calls {
        var setup = 0
        var dashboard = 0
        var quit = 0
    }

    private func hostedFooter(_ calls: Calls) -> NSWindow {
        let footer = PaletteFooter(
            state: AppState(),
            onOpenDashboard: { calls.dashboard += 1 },
            onOpenSetup: { calls.setup += 1 },
            onQuit: { calls.quit += 1 })
        let size = NSRect(x: 0, y: 0, width: 420, height: 120)
        let host = NSHostingView(rootView: footer.frame(width: size.width))
        host.frame = size
        let window = NSWindow(contentRect: size, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func press(_ key: String, keyCode: UInt16, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
        return window.performKeyEquivalent(with: event)
    }

    func test_command_1_opens_setup_once() {
        let calls = Calls()
        let window = hostedFooter(calls)
        defer { window.contentView = nil; window.close() }

        XCTAssertTrue(press("1", keyCode: 18, in: window))
        XCTAssertEqual(calls.setup, 1)
        XCTAssertEqual(calls.dashboard, 0)
        XCTAssertEqual(calls.quit, 0)
    }

    func test_command_2_opens_dashboard() {
        let calls = Calls()
        let window = hostedFooter(calls)
        defer { window.contentView = nil; window.close() }

        XCTAssertTrue(press("2", keyCode: 19, in: window))
        XCTAssertEqual(calls.dashboard, 1)
        XCTAssertEqual(calls.setup, 0)
    }

    func test_command_q_quits() {
        let calls = Calls()
        let window = hostedFooter(calls)
        defer { window.contentView = nil; window.close() }

        XCTAssertTrue(press("q", keyCode: 12, in: window))
        XCTAssertEqual(calls.quit, 1)
    }
}
