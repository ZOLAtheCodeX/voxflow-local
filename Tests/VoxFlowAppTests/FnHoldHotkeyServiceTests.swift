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

        // Release BACK-TO-BACK with the press (no inter-event sleep): the
        // release cancels the pending activation work item ~50 ms before its
        // deadline, deterministically. The old version slept 10 ms before
        // releasing — under load that sleep could overrun the 50 ms
        // activationDelay and fire the press, flaking on the CI runner.
        service.handleFlagsChanged(releaseEvent)

        // Confirm nothing fired, well past the activation delay.
        try await Task.sleep(nanoseconds: 150_000_000)

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
        // Session 29: release is grace-delayed (a flags flicker mid-hold used
        // to truncate the capture instantly), so it fires after the grace
        // window re-confirms fn is really up.
        XCTAssertEqual(releaseCount, 0, "Release must not fire inside the grace window")
        for _ in 0..<200 where releaseCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(releaseCount, 1, "Release should fire after the grace window")
    }

    private func flagsEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: 0.0, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 63)!
    }

    /// Session 29 review: while holding fn and dictating, a brushed modifier
    /// (or flags glitch) made isFnAlone momentarily false → onRelease fired
    /// instantly → capture truncated mid-utterance; the blocked re-press then
    /// swallowed the remainder (matches the field receipts: 0.4-0.8 s captures
    /// 1.2-1.6 s after a previous one). A flicker that resolves back to
    /// fn-alone within the grace window must be a non-event.
    func testFlickerDuringHoldDoesNotFireReleaseOrRePress() async throws {
        let service = FnHoldHotkeyService(activationDelay: 0.05, releaseGraceDelay: 0.08)
        var pressCount = 0
        var releaseCount = 0
        service.register(onPress: { pressCount += 1 }, onRelease: { releaseCount += 1 })

        service.handleFlagsChanged(flagsEvent(.function))
        for _ in 0..<200 where pressCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pressCount, 1)

        // Flicker: fn+command for one flags event, then back to fn-alone
        // well inside the grace window.
        service.handleFlagsChanged(flagsEvent([.function, .command]))
        service.handleFlagsChanged(flagsEvent(.function))

        // Well past the grace window: the flicker must have been absorbed.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(releaseCount, 0, "flicker must not truncate the capture")
        XCTAssertEqual(pressCount, 1, "flicker must not re-fire press")

        // The eventual REAL release still works.
        service.handleFlagsChanged(flagsEvent([]))
        for _ in 0..<200 where releaseCount == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(releaseCount, 1)
    }
}
