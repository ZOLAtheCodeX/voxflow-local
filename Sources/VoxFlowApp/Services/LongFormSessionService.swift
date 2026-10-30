import Foundation
import os
import SwiftUI

/// Injectable clock so tests can advance time deterministically.
protocol SessionClock: AnyObject, Sendable {
    func currentTime() -> Date
}

final class SystemClock: SessionClock {
    func currentTime() -> Date { Date() }
}

/// Long-form dictation session lifecycle (Cockpit Layer 0).
///
/// State machine: ``idle`` → ``recording(startedAt:)`` → ``reviewing``.
/// Pause tolerance: paragraph breaks come from measured pauses passed in by
/// the capture coordinator (not wall-clock time between appends). A pause
/// ≥ ``paragraphBreakPause`` (2 s) before a chunk inserts a soft paragraph
/// break ("\n\n"); shorter pauses join with ``ChunkJoiner``.
/// Auto-save: every 5 s during recording + on stop. Recovery picks the
/// most-recently-updated session JSON on disk.
/// Retention: the session file holds the full plaintext transcript, so
/// ``reset()`` (insert, Notion append, cancel) deletes it permanently with
/// `FileManager.removeItem` (never the Trash, which would keep a copy), and
/// ``init(autoSaveDirectory:clock:orphanRetention:)`` sweeps orphaned
/// session files older than ``orphanRetention`` (7 days).
@MainActor
final class LongFormSessionService: ObservableObject {
    @Published private(set) var state: LongFormState = .idle
    @Published private(set) var currentSession: LongFormSession?
    /// True after 2+ consecutive auto-save failures — the documented crash
    /// recovery contract ("auto-save every ~5 s") is NOT holding, and the
    /// user must be warned instead of dictating for half an hour under a
    /// silently-void safety net (session 29 review). Cleared by the next
    /// successful save.
    @Published private(set) var persistenceFailing = false
    private var consecutiveSaveFailures = 0

    let clock: SessionClock
    private let autoSaveDirectory: URL
    private let log = Logger(subsystem: "local.voxflow.app", category: "LongFormSessionService")
    private var autoSaveTask: Task<Void, Never>?

    static let paragraphBreakPause: TimeInterval = 2.0
    /// How long an orphaned session file (crash, force quit) survives before
    /// the launch sweep removes it.
    static let orphanRetention: TimeInterval = 7 * 24 * 60 * 60
    private static let autoSaveIntervalNs: UInt64 = 5_000_000_000

    init(
        autoSaveDirectory: URL,
        clock: SessionClock = SystemClock(),
        orphanRetention: TimeInterval = LongFormSessionService.orphanRetention
    ) {
        self.autoSaveDirectory = autoSaveDirectory
        self.clock = clock
        try? FileManager.default.createDirectory(
            at: autoSaveDirectory,
            withIntermediateDirectories: true
        )
        sweepOrphans(olderThan: orphanRetention)
    }

    // MARK: - Lifecycle

    func start(targetApp: FocusTargetSnapshot? = nil) {
        // Only legal transition from idle. Starting while recording would
        // leak the prior auto-save Task; starting while reviewing would
        // silently destroy the ready-to-insert transcript. Both are user-
        // surprise bugs that the documented state machine excludes.
        guard case .idle = state else {
            log.warning("start() ignored: already in state \(String(describing: self.state))")
            return
        }
        let session = LongFormSession(targetApp: targetApp)
        currentSession = session
        state = .recording(startedAt: clock.currentTime())
        autoSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.autoSaveIntervalNs)
                guard let self else { return }
                await MainActor.run {
                    if case .recording = self.state {
                        self.save()
                    }
                }
            }
        }
        log.info("session \(session.id.uuidString) started")
    }

    /// Append a transcribed chunk. `pauseBefore` is the measured quiet before
    /// the chunk's first speech; `sessionID` binds the append to the session
    /// that produced it so a stale chunk can never land in a later one.
    func appendChunk(_ chunk: String, pauseBefore: TimeInterval, sessionID: UUID) {
        guard case .recording = state,
              let session = currentSession,
              session.id == sessionID else { return }
        // A transcript cleared to whitespace counts as empty, so the chunk
        // does not follow a leading blank paragraph.
        if session.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            currentSession?.transcript = chunk
        } else if pauseBefore >= Self.paragraphBreakPause {
            currentSession?.transcript = Self.trimmingTrailingWhitespace(session.transcript) + "\n\n" + chunk
        } else {
            currentSession?.transcript = ChunkJoiner.join(session.transcript, chunk)
        }
        currentSession?.updatedAt = clock.currentTime()
    }

    /// Append the visible "[recording interrupted — reason]" marker on its own
    /// paragraph. Same guards as `appendChunk`.
    func appendInterruptionMarker(_ reason: String, sessionID: UUID) {
        guard case .recording = state,
              let session = currentSession,
              session.id == sessionID else { return }
        let trimmed = Self.trimmingTrailingWhitespace(session.transcript)
        let separator = trimmed.isEmpty ? "" : "\n\n"
        currentSession?.transcript = trimmed + separator + "[recording interrupted — \(reason)]"
        currentSession?.updatedAt = clock.currentTime()
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let prev = text.index(before: end)
            guard text[prev].isWhitespace || text[prev].isNewline else { break }
            end = prev
        }
        return String(text[..<end])
    }

    /// Directly overwrite the current session's transcript — used by undo.
    /// No-op when no session is active. Persists immediately so a crash
    /// after undo can't restore the post-action transcript from disk.
    func setTranscript(_ text: String) {
        guard currentSession != nil else { return }
        currentSession?.transcript = text
        currentSession?.updatedAt = clock.currentTime()
        save()
    }

    func recordAppliedAction(_ applied: AppliedAction) {
        currentSession?.appliedActions.append(applied)
        currentSession?.transcript = applied.afterText
        currentSession?.updatedAt = clock.currentTime()
        save()
    }

    func stop() {
        guard case .recording = state else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        state = .reviewing
        save()
        log.info("session stopped at \(self.currentSession?.transcript.count ?? 0) chars")
    }

    func reset() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        let endedID = currentSession?.id
        currentSession = nil
        state = .idle
        if let endedID { removeSessionFile(id: endedID) }
    }

    /// Leaves review without inserting. The session file stays on disk
    /// (sessions are never deleted) and is saved once more first, in case
    /// the last save failed. Refused outside review: discarding a live
    /// recording would leave the microphone running behind an idle session.
    @discardableResult
    func discard() -> Bool {
        guard case .reviewing = state else { return false }
        save()
        reset()
        return true
    }

    // MARK: - Persistence

    private func save() {
        guard let session = currentSession else { return }
        let url = autoSaveDirectory.appendingPathComponent("\(session.id.uuidString).json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session).write(to: url, options: .atomic)
            consecutiveSaveFailures = 0
            if persistenceFailing { persistenceFailing = false }
        } catch {
            log.error("auto-save failed: \(error.localizedDescription)")
            consecutiveSaveFailures += 1
            // A single failure may be transient; two in a row means the
            // safety net is down — surface it. Re-attempt directory creation
            // so a fixed cause (freed disk, restored permissions) self-heals
            // on the next tick without an app restart.
            if consecutiveSaveFailures >= 2 { persistenceFailing = true }
            try? FileManager.default.createDirectory(
                at: autoSaveDirectory, withIntermediateDirectories: true)
        }
    }

    private func removeSessionFile(id: UUID) {
        let url = autoSaveDirectory.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Never saved (reset before the first save), nothing to remove.
        } catch {
            log.error("session file removal failed: \(error.localizedDescription)")
        }
    }

    /// Remove `<uuid>.json` files not modified within `retention`. Files that
    /// are not UUID-named JSON are never touched. A listing failure is logged
    /// and the sweep skipped.
    private func sweepOrphans(olderThan retention: TimeInterval) {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(
                at: autoSaveDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            log.error("orphan sweep skipped: \(error.localizedDescription)")
            return
        }
        let cutoff = clock.currentTime().addingTimeInterval(-retention)
        for url in urls where url.pathExtension == "json" {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                      .contentModificationDate,
                  modified < cutoff else { continue }
            do {
                try fm.removeItem(at: url)
            } catch {
                log.error("orphan session removal failed: \(error.localizedDescription)")
            }
        }
    }

    /// Return the most recently updated long-form session on disk, or nil
    /// when the directory is empty / unreadable. Used at app launch to
    /// offer "resume" of an interrupted session.
    func recoverLatestSession() -> LongFormSession? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: autoSaveDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sessions: [LongFormSession] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(LongFormSession.self, from: data)
            }
        return sessions.max(by: { $0.updatedAt < $1.updatedAt })
    }
}
