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
    private let flushIntervalNs: UInt64
    private let minChunkBytes: Int
    private let log = Logger(subsystem: "local.voxflow.app", category: "CockpitCaptureCoordinator")
    private var loopTask: Task<Void, Never>?
    private var isFlushing = false

    init(
        capture: AudioCapturing,
        transcriber: ChunkTranscribing,
        session: LongFormSessionService,
        dictionary: DictionaryStore? = nil,
        audit: InsertionAuditLog? = nil,
        flushIntervalNs: UInt64 = 5_000_000_000,
        // 0.3 s at 16 kHz mono PCM16 — aligned with the quick-dictation
        // minimum (TranscriptGate.minAudioSeconds); was 8_000 (0.25 s).
        minChunkBytes: Int = 9_600
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.session = session
        self.dictionary = dictionary
        self.audit = audit
        self.flushIntervalNs = flushIntervalNs
        self.minChunkBytes = minChunkBytes
    }

    func startRecording(targetApp: FocusTargetSnapshot?) {
        guard case .idle = session.state else { return }
        session.start(targetApp: targetApp)
        do { try capture.startCapture() } catch {
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
            log.error("stopCapture failed: \(error.localizedDescription)")
            return
        }
        do {
            try capture.startCapture()
        } catch {
            log.error("capture restart failed: \(error.localizedDescription)")
            loopTask?.cancel()
            loopTask = nil
            // Best-effort engine cleanup so the next cockpit recording starts
            // from a known-stopped engine (audit S12). startCapture may have
            // failed mid-setup; a redundant stop throws harmlessly.
            _ = try? capture.stopCapture()
            session.stop()
            return
        }

        guard !audio.isSilent, (force || audio.pcm.count >= minChunkBytes) else { return }
        do {
            let response = try await transcriber.transcribe(audio)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Same ingress gate as quick dictation — this path previously
            // bypassed the confidence rules entirely, so every 5 s flush of
            // ambient noise was a ghost-text opportunity (audit cause #5).
            let durationSeconds = Double(audio.pcm.count) / (audio.sampleRate * 2.0)
            if case .rejected(let reason) = TranscriptGate.evaluate(
                text: text,
                confidence: response.confidenceEstimate,
                audioDurationSeconds: durationSeconds
            ) {
                if reason != "empty" {
                    log.info("TranscriptGate rejected cockpit chunk (\(reason))")
                    audit?.recordRejection(
                        text: text,
                        reason: reason,
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
            log.error("chunk transcription failed: \(error.localizedDescription)")
        }
    }
}
