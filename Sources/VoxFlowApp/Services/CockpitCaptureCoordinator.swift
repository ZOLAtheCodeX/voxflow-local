import Foundation
import os

/// Cockpit Layer 0 — live long-form capture loop.
///
/// Owns a *dedicated* `AudioCapturing` instance (never shared with the palette
/// path, whose start/stop lifecycle is independent). Segments continuous audio
/// into chunks by periodically stop→transcribe→append→restart, feeding text to
/// `LongFormSessionService.appendChunk`.
@MainActor
final class CockpitCaptureCoordinator {
    private let capture: AudioCapturing
    private let transcriber: ChunkTranscribing
    private let session: LongFormSessionService
    private let dictionary: DictionaryStore?
    private let audit: InsertionAuditLog?
    private let rejectedAudio: RejectedAudioStore?
    private let flushIntervalNs: UInt64
    private let minChunkBytes: Int
    /// Consecutive chunk-transcription failures. One or two are transient
    /// (backend hiccup); at `maxConsecutiveTranscriptionFailures` the session
    /// ends cleanly instead of "recording" while every chunk silently
    /// vanishes (session 29 review: backend death 3 min into a 20-minute
    /// session lost 17 minutes with zero signal). Reset on success.
    private var consecutiveTranscriptionFailures = 0
    private static let maxConsecutiveTranscriptionFailures = 3
    /// Fired on the audio thread when the ⌘R start's FIRST buffer arrives —
    /// the same first-buffer gating as the palette path, so the "mic is live"
    /// signal doesn't lead the hardware by ~150 ms and front-clip the first
    /// word of the session. Only the initial start gates: the every-5s
    /// segmentation restarts in `flushNow` deliberately pass no callback (a
    /// cue per flush boundary would ding through the whole session; the
    /// ~150 ms restart gap is inherent to stop→restart segmentation).
    private let onCaptureLive: (@Sendable () -> Void)?
    private let log = Logger(subsystem: "local.voxflow.app", category: "CockpitCaptureCoordinator")
    private var loopTask: Task<Void, Never>?
    private var isFlushing = false

    init(
        capture: AudioCapturing,
        transcriber: ChunkTranscribing,
        session: LongFormSessionService,
        dictionary: DictionaryStore? = nil,
        audit: InsertionAuditLog? = nil,
        rejectedAudio: RejectedAudioStore? = nil,
        flushIntervalNs: UInt64 = 5_000_000_000,
        // 0.3 s at 16 kHz mono PCM16 — aligned with the quick-dictation
        // minimum (TranscriptGate.minAudioSeconds); was 8_000 (0.25 s).
        minChunkBytes: Int = 9_600,
        onCaptureLive: (@Sendable () -> Void)? = nil
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.session = session
        self.dictionary = dictionary
        self.audit = audit
        self.rejectedAudio = rejectedAudio
        self.flushIntervalNs = flushIntervalNs
        self.minChunkBytes = minChunkBytes
        self.onCaptureLive = onCaptureLive
    }

    func startRecording(targetApp: FocusTargetSnapshot?) {
        guard case .idle = session.state else { return }
        session.start(targetApp: targetApp)
        do { try capture.startCapture(onCaptureLive: onCaptureLive) } catch {
            log.error("startCapture failed: \(error.localizedDescription)")
            session.reset()
            return
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.flushIntervalNs ?? 5_000_000_000)
                guard let self else { return }
                await self.flushNow()
            }
        }
    }

    func stopRecording() async {
        loopTask?.cancel()
        loopTask = nil
        await flushNow(force: true)
        _ = try? capture.stopCapture()
        session.stop()
    }

    /// Stop→validate→transcribe→append→restart. Serialized: a second call while
    /// one is in flight is dropped (the timer cadence gates normal flow).
    /// - Parameter force: When `true`, bypasses the minimum-chunk-bytes guard so
    ///   the final tail-audio segment is always transcribed at stop time.
    func flushNow(force: Bool = false) async {
        guard !isFlushing, case .recording = session.state else { return }
        isFlushing = true
        defer { isFlushing = false }

        let audio: CapturedAudio
        do { audio = try capture.stopCapture() } catch {
            // Device change (or dead engine) mid-session. The old log-and-return
            // left the session visibly .recording on a DEAD engine — everything
            // spoken afterward was silently lost until the user noticed
            // (session 29 review). End the session cleanly: transcript so far
            // is preserved into review, and the marker says why.
            log.error("stopCapture failed: \(error.localizedDescription)")
            endSessionAfterInterruption(reason: "audio device changed or capture stopped")
            return
        }
        var restartFailed = false
        do {
            try capture.startCapture()
        } catch {
            log.error("capture restart failed: \(error.localizedDescription)")
            restartFailed = true
        }

        // Transcribe the chunk in hand BEFORE acting on a restart failure —
        // the old order stopped the session and discarded audio it had just
        // successfully collected.
        await transcribeAndAppend(audio, force: force)

        if restartFailed {
            endSessionAfterInterruption(reason: "microphone restart failed")
        }
    }

    private func transcribeAndAppend(_ audio: CapturedAudio, force: Bool) async {
        guard !audio.isSilent, (force || audio.pcm.count >= minChunkBytes) else { return }
        do {
            let response = try await transcriber.transcribe(audio)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            consecutiveTranscriptionFailures = 0
            // Same ingress gate as quick dictation — this path previously
            // bypassed the confidence rules entirely, so every 5 s flush of
            // ambient noise was a ghost-text opportunity (audit cause #5).
            let durationSeconds = audio.durationSeconds
            if case .rejected(let reason) = TranscriptGate.evaluate(
                text: text,
                confidence: response.confidenceEstimate,
                audioDurationSeconds: durationSeconds
            ) {
                if reason != .empty {
                    log.info("TranscriptGate rejected cockpit chunk (\(reason.rawValue))")
                    audit?.recordRejection(
                        text: text,
                        reason: reason.rawValue,
                        confidence: response.confidenceEstimate,
                        durationSeconds: durationSeconds,
                        source: "cockpit_chunk"
                    )
                }
                return
            }
            let corrected = dictionary?.apply(to: text) ?? text
            session.appendChunk(corrected)
        } catch {
            // A failed chunk is a real dictation loss: retain the audio,
            // write a receipt, and after repeated failures end the session
            // instead of silently losing every subsequent chunk.
            log.error("chunk transcription failed: \(error.localizedDescription)")
            consecutiveTranscriptionFailures += 1
            let retained = rejectedAudio?.store(
                pcm: audio.pcm, sampleRate: audio.sampleRate, reason: "transcription_error")
            audit?.recordRejection(
                text: "",
                reason: "transcription_error",
                confidence: 0,
                durationSeconds: audio.durationSeconds,
                source: "cockpit_chunk",
                audioFile: retained?.path
            )
            if consecutiveTranscriptionFailures >= Self.maxConsecutiveTranscriptionFailures {
                endSessionAfterInterruption(reason: "transcription failing repeatedly — audio clips kept")
            }
        }
    }

    /// End a .recording session that can no longer make progress: cancel the
    /// loop, best-effort engine cleanup (a redundant stop throws harmlessly —
    /// audit S12), append a visible marker saying WHY, and move to review so
    /// the transcript so far is preserved and auto-saved.
    private func endSessionAfterInterruption(reason: String) {
        loopTask?.cancel()
        loopTask = nil
        _ = try? capture.stopCapture()
        session.appendChunk("\n\n[recording interrupted — \(reason)]")
        session.stop()
    }
}
