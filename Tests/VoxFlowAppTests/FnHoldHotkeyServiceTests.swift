import XCTest
import AppKit
@testable import VoxFlowApp

final class FnHoldHotkeyServiceTests: XCTestCase {

    func testFnKeyPressDebounceFailure() async throws {
        let service = FnHoldHotkeyService(activationDelay: 0.05)
        var pressCount = 0
        var releaseCount = 0

        service.register(
            onPress: { pressCount += 1 },
            onRelease: { releaseCount += 1 }
        )

        let pressEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .function,
            timestamp: 0.0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        )!

        service.handleFlagsChanged(pressEvent)

        // Immediate release event before 0.05s activation delay
        let releaseEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0.0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        )!

        // Wait 0.01s (less than activationDelay)
        try await Task.sleep(nanoseconds: 10_000_000)
        service.handleFlagsChanged(releaseEvent)

        // Wait another 0.06s (total 0.07s)
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(pressCount, 0, "Press should not trigger since it was released before activationDelay")
        XCTAssertEqual(releaseCount, 0)
    }

    func testFnKeyPressDebounceSuccess() async throws {
        let service = FnHoldHotkeyService(activationDelay: 0.05)
        var pressCount = 0
        var releaseCount = 0

        service.register(
            onPress: { pressCount += 1 },
            onRelease: { releaseCount += 1 }
        )

        let pressEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: .function,
            timestamp: 0.0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        )!

        service.handleFlagsChanged(pressEvent)

        // Condition-based wait, deadline 2 s: a fixed 70 ms sleep left only
        // a 20 ms margin over the 50 ms activationDelay and flaked on a
        // loaded CI runner (passed run 1, failed run 2).
        for _ in 0..<200 where pressCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(pressCount, 1, "Press should trigger after activationDelay")

        let releaseEvent = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0.0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 63
        )!

        service.handleFlagsChanged(releaseEvent)
        XCTAssertEqual(releaseCount, 1, "Release should trigger immediately on releasing Fn alone")
    }
}
