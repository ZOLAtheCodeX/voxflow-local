import Foundation
import XCTest
@testable import VoxFlowApp

extension PasteboardSnapshot {
    /// One item holding one plain-text representation.
    static func text(_ s: String) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [
            .init(representations: [
                .init(type: "public.utf8-plain-text", data: Data(s.utf8))
            ])
        ])
    }
}

/// In-memory `PasteboardAccess`. Models the real pasteboard's change count:
/// every write or restore advances it, and `userCopies` stands in for the user
/// copying something while a temporary paste is in flight.
@MainActor
final class FakePasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private(set) var contents: PasteboardSnapshot
    private(set) var restores: [PasteboardSnapshot] = []
    var failNextWrite = false

    init(_ contents: PasteboardSnapshot = .empty) {
        self.contents = contents
    }

    func snapshot() -> PasteboardSnapshot { contents }

    func writeTemporary(_ text: String) -> Int? {
        changeCount += 1
        if failNextWrite {
            failNextWrite = false
            contents = .empty
            return nil
        }
        contents = .text(text)
        return changeCount
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        changeCount += 1
        contents = snapshot
        restores.append(snapshot)
    }

    func userCopies(_ text: String) {
        changeCount += 1
        contents = .text(text)
    }
}

/// Stands in for `SystemClipboard.copy` so no test writes the developer's real
/// clipboard. `TextInsertionCoordinator` has no default writer, so forgetting to
/// pass one is a compile error.
@MainActor
final class ClipboardRecorder {
    private(set) var copies: [String] = []

    func copy(_ text: String) {
        copies.append(text)
    }
}

/// A sleep the test resumes by hand, so restore-window tests never wait on
/// real time.
@MainActor
final class ManualSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    /// Number of sleeps currently suspended.
    var sleeping: Int { continuations.count }

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuations.append($0) }
    }

    func resumeAll() {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

/// Lets queued main-actor work run.
@MainActor
func drainMainActor() async {
    for _ in 0..<20 { await Task.yield() }
}

/// Yields until `condition` holds (bounded), then asserts it.
@MainActor
func settle(
    until condition: () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<100 {
        if condition() { break }
        await Task.yield()
    }
    XCTAssertTrue(condition(), "condition never held", file: file, line: line)
}
