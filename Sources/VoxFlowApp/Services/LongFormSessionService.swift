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
/// Pause tolerance: silence ≥ ``paragraphBreakSilence`` (4 s) between
/// chunks inserts a soft paragraph break ("\n\n") into the transcript.
/// Auto-save: every 5 s during recording + on stop. Recovery picks the
/// most-recently-updated session JSON on disk.
@MainActor
final class LongFormSessionService: ObservableObject {
    @Published private(set) var state: LongFormState = .idle
    @Published private(set) var currentSession: LongFormSession?

    let clock: SessionClock
    private let autoSaveDirectory: URL
    private let log = Logger(subsystem: "local.voxflow.app", category: "LongFormSessionService")
    private var lastChunkAt: Date?
    private var autoSaveTask: Task<Void, Never>?

    private static let paragraphBreakSilence: TimeInterval = 4.0
    private static let autoSaveIntervalNs: UInt64 = 5_000_000_000

    init(autoSaveDirectory: URL, clock: SessionClock = SystemClock()) {
        self.autoSaveDirectory = autoSaveDirectory
        self.clock = clock
        try? FileManager.default.createDirectory(
            at: autoSaveDirectory,
            withIntermediateDirectories: true
        )
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
        lastChunkAt = nil
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

    func appendChunk(_ chunk: String) {
        guard case .recording = state else { return }
        let now = clock.currentTime()
        if let last = lastChunkAt,
           now.timeIntervalSince(last) >= Self.paragraphBreakSilence,
           let session = currentSession,
           !session.transcript.isEmpty,
           !session.transcript.hasSuffix("\n\n") {
            currentSession?.transcript += "\n\n"
        }
        currentSession?.transcript += chunk
        currentSession?.updatedAt = now
        lastChunkAt = now
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
        currentSession = nil
        state = .idle
        lastChunkAt = nil
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
        } catch {
            log.error("auto-save failed: \(error.localizedDescription)")
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
