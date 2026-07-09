import os
import XCTest
@testable import VoxFlowApp

private final class FakeCapture: AudioCapturing {
    var startCount = 0
    var stopCount = 0
    var failNextStart = false
    var failNextStop = false
    var nextAudio: CapturedAudio
    /// Whether each startCapture call carried a live callback — pins which
    /// starts gate on the first buffer (the initial ⌘R start) and which
    /// deliberately don't (the every-5s segmentation restarts).
    var liveCallbackPresence: [Bool] = []
    var lastLiveCallback: (@Sendable () -> Void)?
    init(nextAudio: CapturedAudio) { self.nextAudio = nextAudio }
    func startCapture(onCaptureLive: (@Sendable () -> Void)?) throws {
        startCount += 1
        liveCallbackPresence.append(onCaptureLive != nil)
        lastLiveCallback = onCaptureLive
        if failNextStart { failNextStart = false; throw AudioCaptureError.captureNotRunning }
    }
    func stopCapture() throws -> CapturedAudio {
        stopCount += 1
        if failNextStop { failNextStop = false; throw AudioCaptureError.deviceChanged }
        return nextAudio
    }
}

private final class FakeTranscriber: ChunkTranscribing, @unchecked Sendable {
    var nextText: String = ""
    /// Number of upcoming transcribe calls that should throw (backend dead,
    /// WhisperKit failure) — decremented per call.
    var failuresRemaining = 0
    /// PCM byte counts of each transcribed chunk — pins the carry semantics.
    private(set) var receivedPCMCounts: [Int] = []
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.cannotConnectToHost)
        }
        receivedPCMCounts.append(audio.pcm.count)
        // TranscribeResponse has no defaults — all 9 fields required (BackendAPIClient.swift:3).
        return TranscribeResponse(
            text: nextText, isFinal: true, latencyMs: 1, confidenceEstimate: 0.9,
            processingTimeMs: 1, stageTimingsMs: nil,
            modelLoadedBeforeRequest: nil, modelLoadedAfterRequest: nil, coldStart: nil)
    }
}

// Note: the `isFlushing` reentrancy guard is correct by inspection — it's a
// synchronous Bool check evaluated before the first `await` on the @MainActor,
// so a concurrent flushNow() bails before any stop/restart. A timing-based test
// for it is inherently racy (continuation-resume ordering) and was removed.

@MainActor
final class CockpitCaptureCoordinatorTests: XCTestCase {
    private func makeAudio(silent: Bool, samples: Int = 8000) -> CapturedAudio {
        var data = Data(count: samples * 2)
        // rmsEnergy = |sample|/Int16.max; isSilent = rmsEnergy < 0.003.
        // Set the HIGH byte of each little-endian Int16 → 0x4000 = 16384 → ~0.5 amplitude, robustly non-silent.
        if !silent { for i in stride(from: 1, to: data.count, by: 2) { data[i] = 0x40 } }
        return CapturedAudio(pcm: data, sampleRate: 16000)
    }

    // MARK: - First-buffer gating (front-clip fix parity with the palette path)

    func test_startRecording_gates_live_hook_on_first_buffer() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let fired = OSAllocatedUnfairLock(initialState: false)
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: FakeTranscriber(), session: session,
            onCaptureLive: { fired.withLock { $0 = true } })
        coord.startRecording(targetApp: nil)
        XCTAssertEqual(capture.liveCallbackPresence, [true], "the ⌘R start must gate on the first buffer")
        XCTAssertFalse(fired.withLock { $0 }, "hook must wait for the first buffer, not engine start")
        capture.lastLiveCallback?()
        XCTAssertTrue(fired.withLock { $0 })
        await coord.stopRecording()
    }

    func test_flush_restart_does_not_reinstall_live_hook() async {
        // The 5 s segmentation restarts would otherwise re-fire the cue on
        // every flush boundary — a ding per chunk.
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: FakeTranscriber(), session: session,
            onCaptureLive: {})
        coord.startRecording(targetApp: nil)
        await coord.flushNow(force: true)
        XCTAssertEqual(capture.liveCallbackPresence, [true, false])
        await coord.stopRecording()
    }

    func test_flushNow_appends_transcribed_text_and_restarts_capture() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "hello world"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        XCTAssertEqual(capture.startCount, 1)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript, "hello world")
        XCTAssertEqual(capture.startCount, 2)
        await coord.stopRecording()
    }

    func test_flushNow_skips_silent_audio() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: true))
        let transcriber = FakeTranscriber(); transcriber.nextText = "should not appear"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }

    func test_flushNow_skips_empty_transcription() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "   "
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }

    func test_flushNow_applies_dictionary_corrections() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "the wherefor clause"
        let dictURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let dict = DictionaryStore(fileURL: dictURL, seedOnFirstRun: false)
        dict.add(wrong: "wherefor", right: "WHEREFORE", context: nil)
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session, dictionary: dict)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript, "the WHEREFORE clause")
        await coord.stopRecording()
    }

    /// Session 29 review: a non-silent chunk under minChunkBytes was
    /// consumed by stopCapture and then DISCARDED — permanent syllable-scale
    /// loss whenever the OS delivered short (e.g. after an IO overload). It
    /// is now carried into the next flush instead.
    func test_subminimum_chunk_is_carried_into_next_flush() async {
        // 0.125 s non-silent chunk — under the 0.3 s minimum.
        let tiny = makeAudio(silent: false, samples: 2000)
        let capture = FakeCapture(nextAudio: tiny)
        let transcriber = FakeTranscriber(); transcriber.nextText = "syllable and sentence"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        await coord.flushNow()
        XCTAssertEqual(transcriber.receivedPCMCounts, [],
                       "sub-minimum chunk must not be transcribed alone")

        // Next window delivers a normal-size chunk; the carried syllable
        // rides in front of it.
        let normal = makeAudio(silent: false, samples: 16_000)
        capture.nextAudio = normal
        await coord.flushNow()

        XCTAssertEqual(transcriber.receivedPCMCounts, [tiny.pcm.count + normal.pcm.count],
                       "carry must be prepended to the next chunk")
        XCTAssertEqual(session.currentSession?.transcript, "syllable and sentence")
        await coord.stopRecording()
    }

    // MARK: - Session 29 review: cockpit chunk-loss paths

    /// A mid-session stopCapture throw (device change) used to log-and-return,
    /// leaving the session visibly .recording with a DEAD engine — everything
    /// spoken afterward was lost silently, for as long as the user didn't
    /// notice. The session must end cleanly with the transcript so far
    /// preserved and an explicit interruption marker.
    func test_stopCapture_throw_ends_session_with_interruption_marker() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "before the change"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()   // appends "before the change"

        capture.failNextStop = true
        await coord.flushNow()   // AirPods disconnect mid-session

        if case .recording = session.state {
            XCTFail("session must not stay .recording on a dead engine")
        }
        let transcript = session.currentSession?.transcript ?? ""
        XCTAssertTrue(transcript.contains("before the change"),
                      "prior chunks must survive the interruption")
        XCTAssertTrue(transcript.contains("interrupted"),
                      "the transcript must say WHY recording ended, got: \(transcript)")
    }

    /// A chunk transcription failure used to be log-only: the audio local was
    /// discarded, no receipt, session kept recording as if nothing happened.
    /// Now: WAV retained, rejection receipt written, session continues (one
    /// failure is transient).
    func test_transcription_failure_retains_audio_and_writes_receipt() async throws {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 1
        let auditURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-audit-\(UUID().uuidString).jsonl")
        let wavDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-wav-\(UUID().uuidString)")
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            audit: InsertionAuditLog(fileURL: auditURL),
            rejectedAudio: RejectedAudioStore(directory: wavDir, maxClips: 4, enabled: true))
        coord.startRecording(targetApp: nil)

        await coord.flushNow()

        if case .recording = session.state {} else {
            XCTFail("a single transcription failure must not end the session")
        }
        let receipt = try String(contentsOf: auditURL, encoding: .utf8)
        XCTAssertTrue(receipt.contains("transcription_error"))
        let wavs = (try? FileManager.default.contentsOfDirectory(atPath: wavDir.path)) ?? []
        XCTAssertEqual(wavs.filter { $0.hasSuffix(".wav") }.count, 1,
                       "the failed chunk's audio must be retained")
        await coord.stopRecording()
    }

    /// Backend death mid-session: without a failure limit, a 20-minute
    /// session kept "recording" while every 5 s chunk silently vanished.
    /// Three consecutive failures end the session with a marker.
    func test_three_consecutive_transcription_failures_stop_session() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 3
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        await coord.flushNow()
        await coord.flushNow()
        if case .recording = session.state {} else {
            XCTFail("two failures must not yet end the session")
        }
        await coord.flushNow()

        if case .recording = session.state {
            XCTFail("three consecutive failures must end the session")
        }
        XCTAssertTrue((session.currentSession?.transcript ?? "").contains("interrupted"))
    }

    /// The restart-failure path used to discard the audio chunk it had JUST
    /// successfully collected — stopping the session without transcribing
    /// the bytes in hand.
    func test_restart_failure_still_appends_in_hand_chunk() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "last words"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStart = true
        await coord.flushNow(force: true)

        if case .recording = session.state {
            XCTFail("session must end after a restart failure")
        }
        XCTAssertTrue((session.currentSession?.transcript ?? "").contains("last words"),
                      "the in-hand chunk must be transcribed before the session ends")
    }

    /// Audit S12: when the mid-chunk capture restart fails, the engine must
    /// be cleaned up with a best-effort stop before the session ends, so the
    /// next cockpit recording starts from a known-stopped engine.
    @MainActor
    func test_flushNow_restart_failure_stops_capture_before_ending_session() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber()
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory)
        let sut = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)

        sut.startRecording(targetApp: nil)
        capture.failNextStart = true
        await sut.flushNow(force: true)

        // stop #1: the flush's stop -> restart fails -> stop #2: cleanup.
        XCTAssertEqual(capture.stopCount, 2)
        if case .recording = session.state {
            XCTFail("session must not stay in .recording after a restart failure")
        }
    }
}
