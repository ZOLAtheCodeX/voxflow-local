import Foundation
import os

/// Cockpit Layer 0 — live long-form capture loop.
///
/// Owns a *dedicated* `AudioCapturing` instance (never shared with the palette
/// path, whose start/stop lifecycle is independent). Segments continuous audio
/// into chunks by periodically stop→transcribe→append→restart, feeding text to
/// `LongFormSessionService.appendChunk`.
///
/// Stop is a drain, not a flush: the tail is cut at the keypress, an in-flight
/// periodic chunk is awaited and appended first, and every append is bound to
/// the session id captured when the recording started, so late work can never
/// touch another session.
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
    /// Non-silent audio under minChunkBytes, carried into the next flush.
    /// stopCapture has already consumed it from the engine — discarding it
    /// (the old behavior) was a permanent syllable-scale loss whenever the
    /// OS delivered short, e.g. right after an IO overload (session 29).
    private var carryPCM = Data()
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
    /// Single-flight stop: a second `stopRecording()` awaits this task.
    private var stopTask: Task<Void, Never>?
    /// The periodic flush in progress, so a stop can await the chunk it
    /// already cut. Cancelling `loopTask` never cancels this.
    private var flushTask: Task<Void, Never>?
    /// True from a successful `startCapture` until ANY `stopCapture` attempt.
    /// `stopCapture` is only called while it is set, so cleanup never hits
    /// `captureNotRunning`. A `deviceChanged` throw also clears it: the
    /// service has already torn the engine down by then, and the audio it
    /// buffered is salvaged with `takeInvalidatedAudio()`.
    private var captureRunning = false
    private var stopRequested = false
    /// Id of the session this recording belongs to. Chunks, markers and the
    /// stop sequence act only while it matches `session.currentSession?.id`.
    private var recordingSessionID: UUID?
    /// Quiet audio, in seconds, that has accumulated since the last appended
    /// text: the trailing quiet of the last chunk that produced text plus
    /// every chunk that added none. The next appended chunk's leading quiet
    /// is added to it to get the pause before that chunk. Never includes the
    /// ~150 ms restart gap, which is not audio.
    private var pendingPause: TimeInterval = 0

    /// Quiet-boundary flush (session 29): the hard timer cut chunks mid-word
    /// at every 5 s seam. The flush now waits — in `flushDeferralStepNs`
    /// steps, up to `maxFlushDeferralNs` — for the live buffer's tail to go
    /// quiet, so the cut lands between words. Bounded: continuous speech
    /// still flushes when the budget runs out; an unknown tail reading
    /// (fakes, short buffer) fails open to the immediate cut.
    private let flushDeferralStepNs: UInt64
    private let maxFlushDeferralNs: UInt64
    /// Window of tail audio judged for the boundary; matches the ~300 ms
    /// inter-word gap floor (TranscriptGate.minAudioSeconds).
    private static let tailWindowSeconds = 0.3

    /// Defer only on ATTESTED speech at the tail. The threshold sits below
    /// the speech floor so trailing weak speech still defers, while room
    /// noise and silence cut immediately.
    nonisolated static func shouldDeferFlush(tailRMS: Double?) -> Bool {
        guard let tailRMS else { return false }
        return tailRMS >= CapturedAudio.speechFloor * 0.75
    }

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
        flushDeferralStepNs: UInt64 = 250_000_000,
        maxFlushDeferralNs: UInt64 = 2_000_000_000,
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
        self.flushDeferralStepNs = flushDeferralStepNs
        self.maxFlushDeferralNs = maxFlushDeferralNs
        self.onCaptureLive = onCaptureLive
    }

    func startRecording(targetApp: FocusTargetSnapshot?) {
        guard stopTask == nil, case .idle = session.state else { return }
        carryPCM = Data()
        consecutiveTranscriptionFailures = 0
        pendingPause = 0
        stopRequested = false
        captureRunning = false
        loopTask?.cancel()
        loopTask = nil
        session.start(targetApp: targetApp)
        recordingSessionID = session.currentSession?.id
        do { try capture.startCapture(onCaptureLive: onCaptureLive) } catch {
            log.error("startCapture failed: \(error.localizedDescription)")
            recordingSessionID = nil
            session.reset()
            return
        }
        captureRunning = true
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.flushIntervalNs ?? 5_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.periodicFlush()
            }
        }
    }

    /// Single-flight: a second call while a stop is draining awaits the same
    /// work and returns.
    func stopRecording() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    /// Stops the engine when it may be running and returns what it buffered.
    /// A device change has already stopped the engine and makes `stopCapture`
    /// throw `deviceChanged` without returning the PCM, so on any failure the
    /// audio buffered before the change is salvaged instead.
    private func stopEngine() -> CapturedAudio? {
        guard captureRunning else { return nil }
        captureRunning = false
        do { return try capture.stopCapture() }
        catch { return capture.takeInvalidatedAudio() }
    }

    /// Cutoff at the keypress: the tail is taken first, then the periodic
    /// chunk already cut (if any) is awaited and appended, then the tail.
    private func performStop() async {
        guard case .recording = session.state, let id = recordingSessionID,
              session.currentSession?.id == id else { return }
        stopRequested = true
        loopTask?.cancel()
        loopTask = nil
        let tail = stopEngine()
        await flushTask?.value
        // A third consecutive failure in the awaited flush may have ended the
        // session. The tail is already out of the engine, so keep it.
        guard case .recording = session.state, session.currentSession?.id == id else {
            if let tail { retainInterruptedAudio(tail.pcm, sampleRate: tail.sampleRate) }
            return
        }
        // Forced: the user already stopped speaking, so the minimum-chunk
        // guard does not apply. This also merges any carried audio.
        await transcribeAndAppend(
            tail ?? CapturedAudio(pcm: Data(), sampleRate: AudioCaptureService.targetSampleRate),
            force: true)
        guard session.currentSession?.id == id else { return }
        session.stop()
    }

    /// One timer-driven cut, run inside `flushTask` so a stop can await it.
    func periodicFlush() async {
        guard flushTask == nil else { return }
        let task = Task { await self.flushNow() }
        flushTask = task
        await task.value
        flushTask = nil
    }

    /// Stop→validate→transcribe→append→restart. Serialized: a second call while
    /// one is in flight is dropped (the timer cadence gates normal flow). The
    /// final tail at stop time is handled by `performStop`, not here.
    /// Production goes through `periodicFlush()` so a stop can await the chunk
    /// this cut; direct calls exist for tests with no concurrent stop.
    func flushNow() async {
        guard !isFlushing, !stopRequested, captureRunning,
              case .recording = session.state,
              let id = recordingSessionID, session.currentSession?.id == id else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Wait (bounded) for a word boundary before cutting. A stop that
        // arrives meanwhile takes this audio as its tail, so abandon the cut.
        var deferredNs: UInt64 = 0
        while deferredNs < maxFlushDeferralNs,
              Self.shouldDeferFlush(
                tailRMS: capture.tailRMSEnergy(seconds: Self.tailWindowSeconds)) {
            try? await Task.sleep(nanoseconds: flushDeferralStepNs)
            deferredNs += flushDeferralStepNs
            guard !stopRequested, case .recording = session.state,
                  session.currentSession?.id == id else { return }
        }

        let audio: CapturedAudio
        do {
            captureRunning = false
            audio = try capture.stopCapture()
        } catch {
            // Device change (or dead engine) mid-session. The old log-and-return
            // left the session visibly .recording on a DEAD engine — everything
            // spoken afterward was silently lost until the user noticed
            // (session 29 review). End the session cleanly: transcript so far
            // is preserved into review, and the marker says why. The engine is
            // already stopped; the cleanup salvages the audio buffered before
            // the change.
            log.error("stopCapture failed: \(error.localizedDescription)")
            endSessionAfterInterruption(reason: "audio device changed or capture stopped")
            return
        }
        var restartFailed = false
        if !stopRequested {
            do {
                try capture.startCapture()
                captureRunning = true
            } catch {
                log.error("capture restart failed: \(error.localizedDescription)")
                restartFailed = true
            }
        }

        // Transcribe the chunk in hand BEFORE acting on a restart failure —
        // the old order stopped the session and discarded audio it had just
        // successfully collected.
        await transcribeAndAppend(audio, force: false)

        if restartFailed, id == recordingSessionID {
            endSessionAfterInterruption(reason: "microphone restart failed")
        }
    }

    /// True while `id` is still the recording this coordinator owns and the
    /// session service still holds that session.
    private func isCurrentRecording(_ id: UUID?) -> Bool {
        id == recordingSessionID && session.currentSession?.id == id
    }

    private func transcribeAndAppend(_ audio: CapturedAudio, force: Bool) async {
        // Bind to the recording this chunk belongs to before any await.
        let id = recordingSessionID
        // Prepend any carried-over sub-minimum audio from the previous flush
        // so the syllable it holds lands in front of this chunk's words.
        var merged = audio
        if !carryPCM.isEmpty {
            merged = CapturedAudio(
                pcm: carryPCM + audio.pcm,
                sampleRate: audio.sampleRate,
                firstBufferLatencyMs: audio.firstBufferLatencyMs,
                bufferLimitReached: audio.bufferLimitReached
            )
            carryPCM = Data()
        }
        // Still under the minimum (and not the forced final flush): stash it
        // for the next window instead of discarding. Bounded — a carry is by
        // definition < minChunkBytes, and it merges or drops next flush.
        if !force, merged.pcm.count < minChunkBytes {
            if !merged.isSilent { carryPCM = merged.pcm }
            return
        }
        // Pause measurements for this merged chunk, taken once before the
        // await. A chunk with no measurable speech (`threshold == nil`) that
        // still yields text is measured at the near-silence fallback instead.
        let threshold = CockpitPauseDetector.quietThreshold(for: merged)
        let wholeQuiet = threshold.map { limit in
            merged.frameRMSValues().allSatisfy { $0 < limit }
        } ?? true
        let measuringThreshold = threshold ?? CapturedAudio.silenceFloor * 3
        let leadingQuiet = merged.leadingQuietSeconds(threshold: measuringThreshold)
        let trailingQuiet = merged.trailingQuietSeconds(threshold: measuringThreshold)
        let mergedSeconds = merged.durationSeconds
        /// A chunk that adds no text: an all-quiet one extends the pending
        /// pause; one with speech restarts it from its own trailing quiet.
        /// Stale work belongs to a newer recording, which owns the counter.
        func settleWithoutText() {
            guard isCurrentRecording(id) else { return }
            pendingPause = wholeQuiet ? pendingPause + mergedSeconds : trailingQuiet
        }
        guard !merged.isSilent else {
            settleWithoutText()
            return
        }
        let audio = merged
        do {
            let response = try await transcriber.transcribe(audio)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isCurrentRecording(id) { consecutiveTranscriptionFailures = 0 }
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
                settleWithoutText()
                return
            }
            let corrected = dictionary?.apply(to: text) ?? text
            if let id {
                // Stale work is rejected by the session's id guard, and must
                // leave the newer recording's counter alone.
                let current = isCurrentRecording(id)
                session.appendChunk(
                    corrected, pauseBefore: current ? pendingPause + leadingQuiet : 0,
                    sessionID: id)
                if current { pendingPause = trailingQuiet }
            }
        } catch {
            // A failed chunk is a real dictation loss: retain the audio,
            // write a receipt, and after repeated failures end the session
            // instead of silently losing every subsequent chunk.
            log.error("chunk transcription failed: \(error.localizedDescription)")
            // Late work from a finished recording still keeps its audio, but
            // must not count against, or end, whatever recording is current.
            let isCurrent = isCurrentRecording(id)
            if isCurrent { consecutiveTranscriptionFailures += 1 }
            settleWithoutText()
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
            if isCurrent,
               consecutiveTranscriptionFailures >= Self.maxConsecutiveTranscriptionFailures {
                endSessionAfterInterruption(reason: "transcription failing repeatedly — audio clips kept")
            }
        }
    }

    /// End a .recording session that can no longer make progress: cancel the
    /// loop, keep every buffered second (carried audio plus whatever the engine
    /// still holds) as an `interrupted_tail` clip, append a visible marker
    /// saying WHY, and move to review so the transcript so far is preserved
    /// and auto-saved.
    private func endSessionAfterInterruption(reason: String) {
        guard case .recording = session.state, let id = recordingSessionID,
              session.currentSession?.id == id else { return }
        loopTask?.cancel()
        loopTask = nil
        var pcm = carryPCM
        carryPCM = Data()
        var sampleRate = AudioCaptureService.targetSampleRate
        if let stopped = stopEngine() ?? capture.takeInvalidatedAudio() {
            pcm += stopped.pcm
            sampleRate = stopped.sampleRate
        }
        retainInterruptedAudio(pcm, sampleRate: sampleRate)
        session.appendInterruptionMarker(reason, sessionID: id)
        session.stop()
    }

    /// Keeps audio that never reached the transcript (buffered tail, carry) so
    /// an interruption loses nothing. Empty and silent audio is dropped.
    private func retainInterruptedAudio(_ pcm: Data, sampleRate: Double) {
        guard !pcm.isEmpty else { return }
        let audio = CapturedAudio(pcm: pcm, sampleRate: sampleRate)
        guard !audio.isSilent else { return }
        let retained = rejectedAudio?.store(pcm: pcm, sampleRate: sampleRate, reason: "interrupted_tail")
        audit?.recordRejection(
            text: "",
            reason: "interrupted_tail",
            confidence: 0,
            durationSeconds: audio.durationSeconds,
            source: "cockpit_chunk",
            audioFile: retained?.path
        )
    }
}
