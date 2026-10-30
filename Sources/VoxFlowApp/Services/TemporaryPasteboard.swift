import Foundation
import os

/// Owns one temporary paste at a time: puts dictated text on the clipboard,
/// lets the caller post Cmd+V, then puts the user's clipboard back.
///
/// The restore after a dispatched paste is deliberately NOT a child of the
/// inserting task. Cmd+V is asynchronous: a slow target (an Electron app) may
/// read the clipboard well after the keystroke is posted. If a cancellation
/// of the inserting task restored the user's clipboard immediately, that
/// target would paste whatever the user had copied before (possibly a
/// password) instead of the dictation. So the restore runs in an unstructured
/// task that only this class cancels (when a newer paste chains onto it, or
/// at `restorePendingNow()`).
///
/// A restore only happens while the clipboard still holds our temporary
/// write (`changeCount` equals the count we recorded). Anything the user
/// copied in the meantime is left alone.
@MainActor
final class TemporaryPasteboard {
    /// How long a dispatched paste keeps the dictation on the clipboard before
    /// the user's content is put back.
    static let consumeDelay: Duration = .milliseconds(300)

    /// Opaque proof of one `place` call. Stale once a newer paste supersedes
    /// it or the clipboard changes under it.
    struct Lease: Equatable {
        fileprivate let id: UInt64
        fileprivate let ownedChangeCount: Int
    }

    private struct Ownership {
        let original: PasteboardSnapshot
        let ownedChangeCount: Int
        let leaseID: UInt64
        var restoreTask: Task<Void, Never>?
    }

    private static let log = Logger(subsystem: "local.voxflow.app", category: "TemporaryPasteboard")

    private let pasteboard: PasteboardAccess
    private let restoreDelay: Duration
    private let sleep: @MainActor (Duration) async throws -> Void
    private var record: Ownership?
    private var nextLeaseID: UInt64 = 0

    init(
        pasteboard: PasteboardAccess = SystemPasteboard(),
        restoreDelay: Duration = TemporaryPasteboard.consumeDelay,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.sleep = sleep
    }

    /// Writes `text` as the temporary clipboard content. Returns nil when the
    /// write fails, after putting the original content back.
    func place(_ text: String) -> Lease? {
        let clock = ContinuousClock()
        let start = clock.now
        let original: PasteboardSnapshot
        if let record, pasteboard.changeCount == record.ownedChangeCount {
            // The clipboard still holds our previous dictation, so the user's
            // content is the original we already hold, not what is there now.
            original = record.original
        } else {
            original = pasteboard.snapshot()
        }
        let snapshotElapsed = start.duration(to: clock.now)
        record?.restoreTask?.cancel()

        guard let ownedChangeCount = pasteboard.writeTemporary(text) else {
            // The failed write may already have cleared the clipboard.
            pasteboard.restore(original)
            record = nil
            return nil
        }

        nextLeaseID += 1
        let leaseID = nextLeaseID
        record = Ownership(
            original: original,
            ownedChangeCount: ownedChangeCount,
            leaseID: leaseID,
            restoreTask: nil
        )
        let milliseconds = snapshotElapsed.components.seconds * 1000
            + snapshotElapsed.components.attoseconds / 1_000_000_000_000_000
        Self.log.info(
            "Temporary paste placed: \(original.items.count) items, \(original.byteCount) bytes saved, snapshot \(milliseconds) ms"
        )
        return Lease(id: leaseID, ownedChangeCount: ownedChangeCount)
    }

    /// True while `lease` is the current paste and the clipboard still holds
    /// its text. Call immediately before posting Cmd+V.
    func stillOwns(_ lease: Lease) -> Bool {
        guard let record, record.leaseID == lease.id else { return false }
        return pasteboard.changeCount == record.ownedChangeCount
    }

    /// Ends the paste. A dispatched paste keeps the dictation on the clipboard
    /// for `restoreDelay` so a slow target can read it; an undispatched one
    /// restores at once. A superseded lease is ignored.
    func release(_ lease: Lease, dispatched: Bool) {
        guard let current = record, current.leaseID == lease.id else { return }
        guard dispatched else {
            restoreIfOwned(leaseID: lease.id)
            return
        }
        record?.restoreTask?.cancel()
        let id = lease.id
        let delay = restoreDelay
        record?.restoreTask = Task { @MainActor [weak self] in
            try? await self?.sleep(delay)
            guard !Task.isCancelled else { return }
            self?.restoreIfOwned(leaseID: id)
        }
    }

    /// Restores a pending paste now, without waiting out the delay. For app
    /// quit, so a terminating process never leaves the dictation on the
    /// clipboard.
    func restorePendingNow() {
        guard let current = record else { return }
        current.restoreTask?.cancel()
        restoreIfOwned(leaseID: current.leaseID)
    }

    private func restoreIfOwned(leaseID: UInt64) {
        guard let current = record, current.leaseID == leaseID else { return }
        if pasteboard.changeCount == current.ownedChangeCount {
            pasteboard.restore(current.original)
        }
        record = nil
    }
}
