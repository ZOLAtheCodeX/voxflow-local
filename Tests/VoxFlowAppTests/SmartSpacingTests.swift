import XCTest
@testable import VoxFlowApp

/// R5.0: successive dictations concatenated without separators
/// ("test.I've tested") — insertions are now boundary-aware.
final class SmartSpacingTests: XCTestCase {

    func testInsertsSpaceAfterSentencePunctuation() {
        XCTAssertEqual(SmartSpacing.adjusted("I've tested it.", precedingCharacter: "."), " I've tested it.")
        XCTAssertEqual(SmartSpacing.adjusted("next point", precedingCharacter: "!"), " next point")
        XCTAssertEqual(SmartSpacing.adjusted("and then", precedingCharacter: "d"), " and then")
    }

    func testNoSpaceWhenBoundaryAlreadyClean() {
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: " "), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "\n"), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: nil), "hello", "empty field / unknown context stays untouched")
    }

    func testNoSpaceAfterOpeningBrackets() {
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "("), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "["), "hello")
        XCTAssertEqual(SmartSpacing.adjusted("hello", precedingCharacter: "\""), "hello")
    }

    func testNoSpaceWhenInsertionStartsWithPunctuationOrSpace(){
        XCTAssertEqual(SmartSpacing.adjusted(", continued", precedingCharacter: "d"), ", continued")
        XCTAssertEqual(SmartSpacing.adjusted(" already spaced", precedingCharacter: "."), " already spaced")
    }

    // MARK: - effectivePrecedingCharacter (AX-unreadable fallback)
    // The AX read returns nil in Electron/web/terminals — the same apps that
    // fall back to paste — so smart-spacing silently no-opped there and
    // dictations ran together. The fallback uses our OWN last insertion into
    // the same target, but ONLY when AX genuinely can't see the field
    // (.unreadable) and the record is fresh.

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func prior(pid: Int32?, trailing: Character?, age: TimeInterval = 0) -> SmartSpacing.PriorInsertion {
        SmartSpacing.PriorInsertion(targetPid: pid, trailingCharacter: trailing, recordedAt: now.addingTimeInterval(-age))
    }

    func testAXReadWinsOverPriorInsertion() {
        // When AX can read the field, that is the source of truth — prior is ignored.
        XCTAssertEqual(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .character("."), prior: prior(pid: 42, trailing: "x"), currentTargetPid: 42, now: now),
            "."
        )
    }

    func testFieldStartNeverFallsBackToPriorInsertion() {
        // AX READ SUCCEEDED and said "cursor at position 0" — an empty or fresh
        // field. That is an authoritative "no preceding character": falling back
        // to the prior insertion here put a stray leading space at the start of
        // new documents in fully AX-readable apps.
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .fieldStart, prior: prior(pid: 42, trailing: "."), currentTargetPid: 42, now: now)
        )
    }

    func testFallsBackToPriorInsertionTrailingCharForSameTarget() {
        // AX unreadable but we last inserted into pid 42 ending in "." —
        // use it so the next dictation gets a leading space.
        XCTAssertEqual(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable, prior: prior(pid: 42, trailing: "."), currentTargetPid: 42, now: now),
            "."
        )
    }

    func testStalePriorInsertionIsIgnored() {
        // The record describes a field we cannot observe: the user may have
        // sent the message, cleared the field, or moved on. Beyond the max age
        // it is more likely wrong than right — drop it.
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable,
                prior: prior(pid: 42, trailing: ".", age: SmartSpacing.priorInsertionMaxAge + 1),
                currentTargetPid: 42,
                now: now)
        )
    }

    func testPriorInsertionJustInsideMaxAgeStillUsed() {
        XCTAssertEqual(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable,
                prior: prior(pid: 42, trailing: ".", age: SmartSpacing.priorInsertionMaxAge - 1),
                currentTargetPid: 42,
                now: now),
            "."
        )
    }

    func testDoesNotReusePriorInsertionAcrossDifferentTargets() {
        // Different focused app — we know nothing about THIS field, so no guess.
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable, prior: prior(pid: 42, trailing: "."), currentTargetPid: 99, now: now)
        )
    }

    func testNoFallbackWithoutPriorInsertion() {
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable, prior: nil, currentTargetPid: 42, now: now)
        )
    }

    func testNoFallbackWhenTargetPidUnknown() {
        // Prior insertion with an unknown (nil) pid can't be confirmed as the
        // same target, so we must not reuse it.
        XCTAssertNil(
            SmartSpacing.effectivePrecedingCharacter(
                axRead: .unreadable, prior: prior(pid: nil, trailing: "."), currentTargetPid: 42, now: now)
        )
    }

    func testFallbackThenAdjustedAddsSpaceInUnreadableApp() {
        // End-to-end of the bug: AX unreadable, prior insertion ended in "."
        // into the same target → the next insertion ("I've tested") gets its space.
        let preceding = SmartSpacing.effectivePrecedingCharacter(
            axRead: .unreadable, prior: prior(pid: 7, trailing: "."), currentTargetPid: 7, now: now)
        XCTAssertEqual(SmartSpacing.adjusted("I've tested", precedingCharacter: preceding), " I've tested")
    }
}
