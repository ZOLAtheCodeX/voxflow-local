import XCTest
@testable import VoxFlowApp

@MainActor
final class TemporaryPasteboardTests: XCTestCase {
    let original = PasteboardSnapshot.text("user copy")

    private func makeSUT(
        _ contents: PasteboardSnapshot? = nil
    ) -> (TemporaryPasteboard, FakePasteboard, ManualSleeper) {
        let fake = FakePasteboard(contents ?? original)
        let sleeper = ManualSleeper()
        let sut = TemporaryPasteboard(pasteboard: fake, sleep: sleeper.sleep)
        return (sut, fake, sleeper)
    }

    func test_dispatched_paste_restores_original_only_after_delay() async throws {
        let (sut, fake, sleeper) = makeSUT()
        let lease = try XCTUnwrap(sut.place("dictated"))
        XCTAssertEqual(fake.contents, .text("dictated"))
        sut.release(lease, dispatched: true)
        await settle { sleeper.sleeping == 1 }
        XCTAssertEqual(fake.contents, .text("dictated"))
        sleeper.resumeAll()
        await settle { fake.restores.count == 1 }
        XCTAssertEqual(fake.contents, original)
    }

    func test_undispatched_release_restores_immediately() throws {
        let (sut, fake, sleeper) = makeSUT()
        let lease = try XCTUnwrap(sut.place("dictated"))
        sut.release(lease, dispatched: false)
        XCTAssertEqual(fake.contents, original)
        XCTAssertEqual(sleeper.sleeping, 0)
    }

    func test_cancelled_caller_does_not_shorten_restore_window() async {
        let (sut, fake, sleeper) = makeSUT()
        let caller = Task { @MainActor in
            if let lease = sut.place("dictated") { sut.release(lease, dispatched: true) }
        }
        caller.cancel()
        await caller.value
        await settle { sleeper.sleeping == 1 }
        XCTAssertEqual(fake.contents, .text("dictated"))
        sleeper.resumeAll()
        await settle { fake.restores.count == 1 }
        XCTAssertEqual(fake.contents, original)
    }

    func test_user_copy_after_dispatch_is_kept() async throws {
        let (sut, fake, sleeper) = makeSUT()
        let lease = try XCTUnwrap(sut.place("dictated"))
        sut.release(lease, dispatched: true)
        await settle { sleeper.sleeping == 1 }
        fake.userCopies("newer")
        sleeper.resumeAll()
        await drainMainActor()
        XCTAssertEqual(fake.contents, .text("newer"))
        XCTAssertTrue(fake.restores.isEmpty)
    }

    func test_user_copy_before_dispatch_is_not_owned() throws {
        let (sut, fake, _) = makeSUT()
        let lease = try XCTUnwrap(sut.place("dictated"))
        fake.userCopies("newer")
        XCTAssertFalse(sut.stillOwns(lease))
        sut.release(lease, dispatched: false)
        XCTAssertEqual(fake.contents, .text("newer"))
        XCTAssertTrue(fake.restores.isEmpty)
    }

    func test_chained_paste_inherits_original_and_restores_once() async throws {
        let (sut, fake, sleeper) = makeSUT()
        let l1 = try XCTUnwrap(sut.place("one"))
        sut.release(l1, dispatched: true)
        await settle { sleeper.sleeping == 1 }
        let l2 = try XCTUnwrap(sut.place("two"))
        XCTAssertEqual(fake.contents, .text("two"))
        sut.release(l2, dispatched: true)
        await settle { sleeper.sleeping == 2 }
        sleeper.resumeAll()
        await settle { fake.restores.count == 1 }
        await drainMainActor()
        XCTAssertEqual(fake.restores, [original])
        XCTAssertEqual(fake.contents, original)
    }

    func test_superseded_lease_release_is_a_no_op() throws {
        let (sut, fake, _) = makeSUT()
        let l1 = try XCTUnwrap(sut.place("one"))
        let l2 = try XCTUnwrap(sut.place("two"))
        sut.release(l1, dispatched: false)
        XCTAssertEqual(fake.contents, .text("two"))
        XCTAssertTrue(fake.restores.isEmpty)
        sut.release(l2, dispatched: false)
        XCTAssertEqual(fake.restores, [original])
    }

    func test_empty_original_is_restored_empty() throws {
        let (sut, fake, _) = makeSUT(.empty)
        let lease = try XCTUnwrap(sut.place("dictated"))
        sut.release(lease, dispatched: false)
        XCTAssertEqual(fake.contents, .empty)
    }

    func test_write_failure_restores_original_and_returns_nil() {
        let (sut, fake, _) = makeSUT()
        fake.failNextWrite = true
        XCTAssertNil(sut.place("x"))
        XCTAssertEqual(fake.contents, original)
    }

    func test_restore_pending_now_restores_without_waiting() async throws {
        let (sut, fake, sleeper) = makeSUT()
        let lease = try XCTUnwrap(sut.place("dictated"))
        sut.release(lease, dispatched: true)
        await settle { sleeper.sleeping == 1 }
        sut.restorePendingNow()
        XCTAssertEqual(fake.contents, original)
        sleeper.resumeAll()
        await drainMainActor()
        XCTAssertEqual(fake.restores.count, 1)
    }

    func test_paste_after_completed_restore_snapshots_current_clipboard() throws {
        let (sut, fake, _) = makeSUT()
        let l1 = try XCTUnwrap(sut.place("one"))
        sut.release(l1, dispatched: false)
        fake.userCopies("later copy")
        let l2 = try XCTUnwrap(sut.place("two"))
        sut.release(l2, dispatched: false)
        XCTAssertEqual(fake.contents, .text("later copy"))
    }
}
