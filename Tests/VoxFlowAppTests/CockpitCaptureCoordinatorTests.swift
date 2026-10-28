import os
import XCTest
@testable import VoxFlowApp

private final class FakeCapture: AudioCapturing {
    var startCount = 0
    var stopCount = 0
    var failNextStart = false
    var failNextStop = false
    var nextAudio: CapturedAudio
    /// Audio served by successive stopCapture calls before `nextAudio` takes
    /// over, so a test can tell the periodic chunk from the stop's tail.
    var queue: [CapturedAudio] = []
    /// Mirrors AudioCaptureService: true between a successful start and a
    /// successful stop. A stop while stopped is a coordinator bug.
    private(set) var isRunning = false
    /// Audio a device change invalidated: AudioCaptureService.stopCapture
    /// throws deviceChanged without returning it, so it is only reachable
    /// through `takeInvalidatedAudio()`.
    private var invalidatedAudio: CapturedAudio?
    var restartCount: Int { max(0, startCount - 1) }
    /// Scripted tail energy + consult counter for the quiet-boundary flush.
    var tailRMSValue: Double?
    private(set) var tailRMSConsults = 0
    func tailRMSEnergy(seconds: Double) -> Double? {
        tailRMSConsults += 1
        return tailRMSValue
    }
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
        isRunning = true
    }
    func stopCapture() throws -> CapturedAudio {
        stopCount += 1
        guard isRunning else {
            XCTFail("stopCapture on a stopped engine")
            throw AudioCaptureError.captureNotRunning
        }
        let audio = queue.isEmpty ? nextAudio : queue.removeFirst()
        isRunning = false
        // handleConfigurationChange already stopped the engine, so the throw
        // leaves it stopped and the buffered audio is only salvageable.
        if failNextStop {
            failNextStop = false
            invalidatedAudio = audio
            throw AudioCaptureError.deviceChanged
        }
        return audio
    }
    func takeInvalidatedAudio() -> CapturedAudio? {
        defer { invalidatedAudio = nil }
        return invalidatedAudio
    }
}

/// Yields until `condition` holds, a bounded number of times. On exhaustion it
/// fails the test instead of hanging the suite, and returns false. Shared by
/// the cockpit test files.
@MainActor
func yieldUntil(
    _ condition: () -> Bool, limit: Int = 10_000, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
) async -> Bool {
    for _ in 0..<limit {
        if condition() { return true }
        await Task.yield()
    }
    if condition() { return true }
    XCTFail(message, file: file, line: line)
    return false
}

/// A completion flag a test task sets after its awaited call returns, so a
/// test can tell a call that is still waiting from one that returned.
@MainActor
final class DoneFlag {
    var isDone = false
}

@MainActor
private final class FakeTranscriber: ChunkTranscribing {
    var nextText: String = ""
    /// Per-call text and confidence, falling back to `nextText` and 0.9.
    var texts: [String] = []
    var confidences: [Double] = []
    /// Number of upcoming transcribe calls that should throw (backend dead,
    /// WhisperKit failure) — decremented per call.
    var failuresRemaining = 0
    /// Zero-based call indexes that throw, for a failure between successes.
    var failingCalls: Set<Int> = []
    /// PCM byte counts of each transcribed chunk — pins the carry semantics.
    private(set) var receivedPCMCounts: [Int] = []
    /// While positive, each call suspends until `releaseNext()`.
    var holdCalls = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var callIndex = 0
    var heldCount: Int { held.count }

    func releaseNext() {
        guard !held.isEmpty else { return }
        held.removeFirst().resume()
    }

    func waitUntilHeld(
        _ n: Int, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        await yieldUntil({ held.count >= n }, "transcriber never held \(n) call(s)", file: file, line: line)
    }

    /// Frees every suspended call and stops holding, so a failed wait cannot
    /// leave tasks (and the suite) hanging.
    func releaseAll() {
        holdCalls = 0
        let pending = held
        held = []
        pending.forEach { $0.resume() }
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        let index = callIndex
        callIndex += 1
        if holdCalls > 0 {
            holdCalls -= 1
            await withCheckedContinuation { held.append($0) }
        }
        if failingCalls.contains(index) { throw URLError(.cannotConnectToHost) }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.cannotConnectToHost)
        }
        receivedPCMCounts.append(audio.pcm.count)
        // TranscribeResponse has no defaults — all 9 fields required (BackendAPIClient.swift:3).
        return TranscribeResponse(
            text: index < texts.count ? texts[index] : nextText, isFinal: true, latencyMs: 1,
            confidenceEstimate: index < confidences.count ? confidences[index] : 0.9,
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
        await coord.flushNow()
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

    // MARK: - Quiet-boundary flush (session 29 deferred item)

    /// The hard 5 s timer cut chunks mid-word at every seam. The flush now
    /// defers (bounded) until the buffer tail goes quiet, so the cut lands
    /// between words. Pure decision: defer only on ATTESTED speech at the
    /// tail — an unknown reading (nil) must fail open to the old behavior.
    func test_shouldDeferFlush_decision() {
        XCTAssertTrue(CockpitCaptureCoordinator.shouldDeferFlush(tailRMS: 0.05))
        XCTAssertFalse(CockpitCaptureCoordinator.shouldDeferFlush(tailRMS: 0.004),
                       "quiet tail = word boundary, cut now")
        XCTAssertFalse(CockpitCaptureCoordinator.shouldDeferFlush(tailRMS: nil),
                       "unknown tail energy must not stall the flush")
    }

    /// Speech at the tail defers the flush (multiple energy consults) but the
    /// deferral budget bounds it — the flush must still happen.
    func test_flush_defers_while_tail_is_speech_then_cuts() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        capture.tailRMSValue = 0.06   // speech at the tail, forever
        let transcriber = FakeTranscriber(); transcriber.nextText = "still flushed"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            flushDeferralStepNs: 5_000_000,     // 5 ms steps for the test
            maxFlushDeferralNs: 25_000_000)     // 25 ms budget
        coord.startRecording(targetApp: nil)

        await coord.flushNow()

        XCTAssertGreaterThan(capture.tailRMSConsults, 1,
                             "speech tail must be re-checked across the deferral budget")
        XCTAssertEqual(session.currentSession?.transcript, "still flushed",
                       "budget exhaustion must still flush")
        await coord.stopRecording()
    }

    func test_flush_cuts_immediately_on_quiet_tail() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        capture.tailRMSValue = 0.002  // quiet tail — a word boundary
        let transcriber = FakeTranscriber(); transcriber.nextText = "prompt cut"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            flushDeferralStepNs: 5_000_000, maxFlushDeferralNs: 25_000_000)
        coord.startRecording(targetApp: nil)

        await coord.flushNow()

        XCTAssertEqual(capture.tailRMSConsults, 1, "quiet tail flushes on the first check")
        XCTAssertEqual(session.currentSession?.transcript, "prompt cut")
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
        await coord.flushNow()

        if case .recording = session.state {
            XCTFail("session must end after a restart failure")
        }
        XCTAssertTrue((session.currentSession?.transcript ?? "").contains("last words"),
                      "the in-hand chunk must be transcribed before the session ends")
    }

    /// Audit S12: when the mid-chunk capture restart fails the session must
    /// end. AudioCaptureService.startCapture removes its own tap when
    /// engine.start() throws, so no second stop is needed (it could only
    /// throw captureNotRunning); the fake fails the test on a stop-while-stopped.
    @MainActor
    func test_flushNow_restart_failure_stops_capture_before_ending_session() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber()
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory)
        let sut = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)

        sut.startRecording(targetApp: nil)
        capture.failNextStart = true
        await sut.flushNow()

        XCTAssertEqual(capture.stopCount, 1)
        if case .recording = session.state {
            XCTFail("session must not stay in .recording after a restart failure")
        }
    }

    // MARK: - Safe drain, session binding, interruption tail retention

    private func makeSession() -> LongFormSessionService {
        LongFormSessionService(
            autoSaveDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString))
    }

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-wav-\(UUID().uuidString)")
    }

    private func clipNames(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    func test_stop_during_inflight_transcription_appends_chunk_then_tail() async {
        let a = makeAudio(silent: false, samples: 8000), b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: a); capture.queue = [a, b]
        let transcriber = FakeTranscriber()
        transcriber.texts = ["first part", "second part"]; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop = Task { await coord.stopRecording() }
        guard await yieldUntil({ capture.stopCount >= 2 }, "stop never reached 2 stopCapture calls") else { transcriber.releaseAll(); return }   // the tail is cut at the keypress
        transcriber.releaseNext()
        _ = await stop.value; await flush.value

        XCTAssertEqual(session.currentSession?.transcript, "first part second part")
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertEqual(transcriber.receivedPCMCounts, [16_000, 8_000])
    }

    func test_tail_is_cut_at_the_keypress() async {
        let a = makeAudio(silent: false, samples: 8000), b = makeAudio(silent: false, samples: 4000)
        let c = makeAudio(silent: false, samples: 6000)
        let capture = FakeCapture(nextAudio: a); capture.queue = [a, b, c]
        let transcriber = FakeTranscriber()
        transcriber.texts = ["first part", "second part"]; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop = Task { await coord.stopRecording() }
        guard await yieldUntil({ capture.stopCount >= 2 }, "stop never reached 2 stopCapture calls") else { transcriber.releaseAll(); return }
        transcriber.releaseNext()
        _ = await stop.value; await flush.value

        XCTAssertEqual(capture.queue.count, 1, "audio after the keypress must never be served")
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertEqual(capture.restartCount, 1)
    }

    func test_double_stop_appends_tail_once_and_never_restarts() async {
        let a = makeAudio(silent: false, samples: 8000), b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: a); capture.queue = [a, b]
        let transcriber = FakeTranscriber()
        transcriber.texts = ["first part", "second part"]; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop1 = Task { await coord.stopRecording() }
        let stop2 = Task { await coord.stopRecording() }
        guard await yieldUntil({ capture.stopCount >= 2 }, "stop never reached 2 stopCapture calls") else { transcriber.releaseAll(); return }
        transcriber.releaseNext()
        _ = await stop1.value; _ = await stop2.value; await flush.value

        let transcript = session.currentSession?.transcript ?? ""
        XCTAssertEqual(occurrences(of: "second part", in: transcript), 1)
        XCTAssertEqual(capture.stopCount, 2)
        XCTAssertEqual(capture.restartCount, 1)
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_stop_during_flush_deferral_abandons_the_cut() async {
        let b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: b); capture.queue = [b]
        capture.tailRMSValue = 0.05   // speech at the tail, forever
        let transcriber = FakeTranscriber(); transcriber.nextText = "tail words"
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            flushDeferralStepNs: 1_000_000, maxFlushDeferralNs: 10_000_000_000)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await yieldUntil({ capture.tailRMSConsults >= 1 }, "flush never consulted the tail") else {
            await coord.stopRecording(); return
        }
        await coord.stopRecording()
        await flush.value

        XCTAssertEqual(transcriber.receivedPCMCounts, [8_000])
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.restartCount, 0)
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_stop_after_restart_failure_issues_no_stop() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "last words"
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStart = true
        await coord.periodicFlush()   // the session ends on the restart failure
        await coord.stopRecording()

        XCTAssertEqual(capture.stopCount, 1, "no stop may hit an engine that is already stopped")
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_start_is_refused_while_a_stop_drains() async {
        let a = makeAudio(silent: false, samples: 8000), b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: a); capture.queue = [a, b]
        let transcriber = FakeTranscriber(); transcriber.nextText = "words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop = Task { await coord.stopRecording() }
        guard await yieldUntil({ capture.stopCount >= 2 }, "stop never reached 2 stopCapture calls") else { transcriber.releaseAll(); return }

        session.reset()
        let startsBefore = capture.startCount
        coord.startRecording(targetApp: nil)
        XCTAssertEqual(capture.startCount, startsBefore, "a stop in progress must fence off a new start")
        XCTAssertEqual(session.state, .idle)

        transcriber.releaseNext()
        _ = await stop.value; await flush.value
    }

    /// Review Focus 1: a device change has already stopped the engine, so
    /// stopCapture throws deviceChanged and never returns the PCM. The audio
    /// buffered before the change must still reach the transcript.
    func test_stop_with_device_change_keeps_tail_from_invalidated_capture() async {
        let b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: b); capture.queue = [b]
        let transcriber = FakeTranscriber(); transcriber.nextText = "the tail words"
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStop = true
        await coord.stopRecording()

        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(session.currentSession?.transcript, "the tail words")
        XCTAssertEqual(session.state, .reviewing)
    }

    /// The audio buffered before a device change at a periodic cut is
    /// transcribed before the session ends, so its words land in front of
    /// the marker. Nothing is left over for an interrupted_tail clip.
    func test_device_change_at_periodic_cut_transcribes_buffered_audio_before_the_marker() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "salvaged words"
        let wavDir = makeTempDir()
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            rejectedAudio: RejectedAudioStore(directory: wavDir, maxClips: 8, enabled: true))
        coord.startRecording(targetApp: nil)

        capture.failNextStop = true
        await coord.periodicFlush()

        XCTAssertEqual(session.currentSession?.transcript,
                       "salvaged words\n\n[recording interrupted — audio device changed or capture stopped]")
        XCTAssertEqual(clipNames(wavDir).filter { $0.contains("interrupted_tail") }.count, 0)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(capture.restartCount, 0)
        XCTAssertEqual(session.state, .reviewing)
    }

    /// The salvaged audio goes through the transcriber's normal failure path:
    /// a failed transcription still keeps the clip.
    func test_device_change_at_periodic_cut_keeps_the_clip_when_transcription_fails() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 1
        let wavDir = makeTempDir()
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            rejectedAudio: RejectedAudioStore(directory: wavDir, maxClips: 8, enabled: true))
        coord.startRecording(targetApp: nil)

        capture.failNextStop = true
        await coord.periodicFlush()

        let names = clipNames(wavDir)
        XCTAssertEqual(names.filter { $0.contains("transcription_error") }.count, 1)
        XCTAssertEqual(names.filter { $0.contains("interrupted_tail") }.count, 0)
        XCTAssertEqual(session.currentSession?.transcript,
                       "[recording interrupted — audio device changed or capture stopped]")
        XCTAssertEqual(session.state, .reviewing)
    }

    /// The salvage transcription awaits. A recording started meanwhile (the
    /// old one cancelled from review) belongs to someone else: the late
    /// cleanup must not end it or stop its engine.
    func test_device_change_salvage_does_not_end_a_newer_recording() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber()
        transcriber.nextText = "stale words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStop = true
        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        session.stop(); session.reset()   // the user cancels, then records again
        coord.startRecording(targetApp: nil)
        transcriber.releaseNext()
        await flush.value

        guard case .recording = session.state else {
            return XCTFail("the newer recording must keep recording, got \(session.state)")
        }
        XCTAssertEqual(session.currentSession?.transcript, "")
        XCTAssertTrue(capture.isRunning, "the newer recording's engine must stay on")
        _ = await coord.stopRecording()
    }

    func test_third_failure_interruption_retains_buffered_tail() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 3
        let wavDir = makeTempDir()
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            rejectedAudio: RejectedAudioStore(directory: wavDir, maxClips: 8, enabled: true))
        coord.startRecording(targetApp: nil)

        await coord.periodicFlush()
        await coord.periodicFlush()
        await coord.periodicFlush()

        let names = clipNames(wavDir)
        XCTAssertEqual(names.filter { $0.contains("transcription_error") }.count, 3)
        XCTAssertEqual(names.filter { $0.contains("interrupted_tail") }.count, 1)
        XCTAssertTrue((session.currentSession?.transcript ?? "").hasSuffix(
            "[recording interrupted — transcription failing repeatedly — audio clips kept]"))
        XCTAssertEqual(session.state, .reviewing)
    }

    /// Review Focus 2: the third failure lands while a stop is awaiting the
    /// flush, after the stop already took the tail. That tail must be kept.
    func test_interruption_during_stop_retains_taken_tail() async {
        let a = makeAudio(silent: false, samples: 8000), b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: a); capture.queue = [a, a, a, b]
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 3
        let wavDir = makeTempDir()
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(
            capture: capture, transcriber: transcriber, session: session,
            rejectedAudio: RejectedAudioStore(directory: wavDir, maxClips: 8, enabled: true))
        coord.startRecording(targetApp: nil)

        await coord.periodicFlush()
        await coord.periodicFlush()
        transcriber.holdCalls = 1
        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop = Task { await coord.stopRecording() }
        guard await yieldUntil({ capture.stopCount >= 4 }, "stop never reached 4 stopCapture calls") else { transcriber.releaseAll(); return }   // the stop took the tail
        transcriber.releaseNext()
        _ = await stop.value; await flush.value

        let names = clipNames(wavDir)
        XCTAssertEqual(names.filter { $0.contains("interrupted_tail") }.count, 1)
        XCTAssertEqual(names.filter { $0.contains("transcription_error") }.count, 3)
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_late_chunk_from_old_session_is_ignored() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "stale words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        session.stop(); session.reset(); session.start()   // a different session id
        transcriber.releaseNext()
        await flush.value

        XCTAssertEqual(session.currentSession?.transcript, "")
    }

    func test_new_recording_starts_with_empty_carry() async {
        let tiny = makeAudio(silent: false, samples: 4000)   // 8000 bytes, under the minimum
        let capture = FakeCapture(nextAudio: tiny)
        let transcriber = FakeTranscriber(); transcriber.nextText = "fresh words"
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()   // carried, not transcribed
        XCTAssertEqual(transcriber.receivedPCMCounts, [])

        session.stop(); session.reset()   // bypasses stopRecording on purpose
        let normal = makeAudio(silent: false, samples: 16_000)
        capture.nextAudio = normal
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()

        XCTAssertEqual(transcriber.receivedPCMCounts.last, normal.pcm.count,
                       "the previous recording's carry must not leak into this one")
    }

    func test_new_recording_starts_with_zero_failure_count() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 2
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()
        await coord.periodicFlush()

        session.stop(); session.reset()   // bypasses stopRecording on purpose
        transcriber.failuresRemaining = 1
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()

        if case .recording = session.state {} else {
            XCTFail("a stale failure count would have ended this recording on its first failure")
        }
    }

    func test_second_stop_during_tail_transcription_keeps_the_tail() async {
        let b = makeAudio(silent: false, samples: 4000)
        let capture = FakeCapture(nextAudio: b); capture.queue = [b]
        let transcriber = FakeTranscriber()
        transcriber.nextText = "the tail words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let stop1 = Task { await coord.stopRecording() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop2Done = DoneFlag()
        let stop2 = Task {
            await coord.stopRecording()
            stop2Done.isDone = true
        }
        // Give a second stop that wrongly returns early every chance to do so.
        for _ in 0..<100 where !stop2Done.isDone { await Task.yield() }
        XCTAssertFalse(stop2Done.isDone, "the second stop must wait for the drain it joined")
        transcriber.releaseNext()
        _ = await stop1.value; _ = await stop2.value
        XCTAssertTrue(stop2Done.isDone)

        let transcript = session.currentSession?.transcript ?? ""
        XCTAssertEqual(occurrences(of: "the tail words", in: transcript), 1)
        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_stop_during_restart_failure_flush_keeps_chunk_and_marker() async {
        let a = makeAudio(silent: false, samples: 8000)
        let capture = FakeCapture(nextAudio: a)
        let transcriber = FakeTranscriber()
        transcriber.nextText = "chunk words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStart = true
        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop = Task { await coord.stopRecording() }
        for _ in 0..<10 { await Task.yield() }   // let the stop start draining
        transcriber.releaseNext()
        _ = await stop.value; await flush.value

        let transcript = session.currentSession?.transcript ?? ""
        XCTAssertTrue(transcript.contains("chunk words"))
        XCTAssertTrue(transcript.contains("[recording interrupted — microphone restart failed]"))
        XCTAssertEqual(capture.stopCount, 1)
    }

    // MARK: - Drain result

    func test_stopRecording_reports_a_clean_drain() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "the tail words"
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let drained = await coord.stopRecording()

        XCTAssertTrue(drained)
        XCTAssertEqual(session.state, .reviewing)
    }

    func test_stopRecording_with_nothing_recording_reports_no_drain() async {
        let coord = CockpitCaptureCoordinator(
            capture: FakeCapture(nextAudio: makeAudio(silent: false)),
            transcriber: FakeTranscriber(), session: makeSession())

        let drained = await coord.stopRecording()

        XCTAssertFalse(drained)
    }

    func test_joined_stop_reports_the_same_clean_drain() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false, samples: 4000))
        let transcriber = FakeTranscriber()
        transcriber.nextText = "the tail words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        let stop1 = Task { await coord.stopRecording() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop2 = Task { await coord.stopRecording() }
        for _ in 0..<10 { await Task.yield() }   // let the second stop join
        transcriber.releaseNext()
        let first = await stop1.value, second = await stop2.value

        XCTAssertTrue(first)
        XCTAssertTrue(second, "a joined stop gets the result of the drain it joined")
    }

    /// The restart-failure flush ends the session with a marker while the
    /// stop awaits it. That is an interruption, not a clean drain, for the
    /// stop and for every stop that joined it.
    func test_stop_joining_an_interrupted_flush_reports_no_drain() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false, samples: 8000))
        let transcriber = FakeTranscriber()
        transcriber.nextText = "chunk words"; transcriber.holdCalls = 1
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)

        capture.failNextStart = true
        let flush = Task { await coord.periodicFlush() }
        guard await transcriber.waitUntilHeld(1) else { transcriber.releaseAll(); return }
        let stop1 = Task { await coord.stopRecording() }
        let stop2 = Task { await coord.stopRecording() }
        for _ in 0..<10 { await Task.yield() }   // let both stops start draining
        transcriber.releaseNext()
        let first = await stop1.value, second = await stop2.value
        await flush.value

        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertTrue((session.currentSession?.transcript ?? "").hasSuffix(
            "[recording interrupted — microphone restart failed]"))
    }

    /// The tail's own transcription is the third consecutive failure, so the
    /// session ends through the interruption path inside the stop.
    func test_stop_whose_tail_ends_the_session_reports_no_drain() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.failuresRemaining = 3
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()
        await coord.periodicFlush()

        let drained = await coord.stopRecording()

        XCTAssertFalse(drained)
        XCTAssertEqual(session.state, .reviewing)
        XCTAssertTrue((session.currentSession?.transcript ?? "").hasSuffix(
            "[recording interrupted — transcription failing repeatedly — audio clips kept]"))
    }

    // MARK: - Pause accounting across chunk boundaries

    /// Runs one `periodicFlush()` per queued chunk, then stops, and returns the
    /// final transcript. The stop's tail is a short silent buffer unless the
    /// caller queued one more chunk.
    private func transcriptAfterFlushes(
        _ chunks: [CapturedAudio], texts: [String], confidences: [Double] = [],
        failingCalls: Set<Int> = [], extraTail: CapturedAudio? = nil
    ) async -> String {
        let capture = FakeCapture(nextAudio: makeAudio(silent: true, samples: 1600))
        capture.queue = chunks + (extraTail.map { [$0] } ?? [])
        let transcriber = FakeTranscriber()
        transcriber.texts = texts
        transcriber.confidences = confidences
        transcriber.failingCalls = failingCalls
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        for _ in chunks { await coord.periodicFlush() }
        await coord.stopRecording()
        return session.currentSession?.transcript ?? ""
    }

    func test_continuous_speech_across_three_flushes_is_one_paragraph() async {
        let chunk = makeTone([(5.0, 0.08)])
        let transcript = await transcriptAfterFlushes(
            [chunk, chunk, chunk], texts: ["one", "two", "three"])
        XCTAssertEqual(transcript, "one two three")
    }

    func test_quiet_span_across_boundary_breaks_once() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (1.2, 0)]), makeTone([(1.0, 0), (3.0, 0.08)])],
            texts: ["one", "two"])
        XCTAssertEqual(transcript, "one\n\ntwo")
    }

    func test_short_quiet_span_across_boundary_joins() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (0.95, 0)]), makeTone([(0.95, 0), (3.0, 0.08)])],
            texts: ["one", "two"])
        XCTAssertEqual(transcript, "one two")
    }

    func test_all_quiet_window_between_speech_breaks() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(5.0, 0.08)]), makeTone([(5.0, 0.004)]), makeTone([(5.0, 0.08)])],
            texts: ["one", "", "three"])
        XCTAssertEqual(transcript, "one\n\nthree")
    }

    func test_gate_rejected_speech_chunk_does_not_create_break() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (1.5, 0)]),
             makeTone([(5.0, 0.08)]),
             makeTone([(1.0, 0), (4.0, 0.08)])],
            texts: ["one", "um", "three"], confidences: [0.9, 0.05, 0.9])
        XCTAssertEqual(transcript, "one three")
    }

    func test_carried_subminimum_merge_counts_once() async {
        // 8000 bytes (below the 9600-byte minimum) is carried, then merged into
        // the next flush. Counting the carry's quiet lead twice would reach 2.0.
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (1.8, 0)]),
             makeTone([(0.15, 0), (0.1, 0.08)]),
             makeTone([(0.7, 0), (4.0, 0.08)])],
            texts: ["one", "three"])
        XCTAssertEqual(transcript, "one three")
    }

    func test_short_word_after_long_quiet_does_not_break_next_chunk() async {
        // The first chunk's p95 is room noise (quietThreshold is nil) yet it
        // produced text, so its trailing quiet is measured at the fallback
        // threshold: the short word ends it and nothing carries forward.
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.8, 0.004), (0.2, 0.08)]), makeTone([(5.0, 0.08)])],
            texts: ["hello", "world"])
        XCTAssertEqual(transcript, "hello world")
    }

    /// Ruling R3a: sustained weak speech (p95 under 3x the silence floor, so
    /// no measured threshold) is measured at the detector's own floor, so the
    /// speech never reads as quiet and continuous chunks join.
    func test_sustained_weak_speech_across_boundary_joins() async {
        let chunk = makeTone([(5.0, 0.008)])
        let transcript = await transcriptAfterFlushes([chunk, chunk], texts: ["one", "two"])
        XCTAssertEqual(transcript, "one two")
    }

    func test_room_noise_below_the_floor_still_counts_as_quiet() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(5.0, 0.08)]), makeTone([(2.5, 0.004), (2.5, 0.008)])],
            texts: ["one", "two"])
        XCTAssertEqual(transcript, "one\n\ntwo")
    }

    /// A chunk whose transcription throws had speech in it, so it restarts
    /// the pending pause from its own trailing quiet, like a gate rejection.
    /// The 1.5 s before it plus its 1.0 s lead must not carry forward.
    func test_transcription_error_chunk_restarts_the_pending_pause() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (1.5, 0)]),
             makeTone([(1.0, 0), (4.0, 0.08)]),
             makeTone([(0.6, 0), (4.4, 0.08)])],
            texts: ["one", "", "three"], failingCalls: [1])
        XCTAssertEqual(transcript, "one three")
    }

    func test_new_recording_does_not_inherit_pending_pause() async {
        let capture = FakeCapture(nextAudio: makeTone([(5.0, 0.08)]))
        capture.queue = [makeTone([(4.0, 0.08), (2.5, 0)])]
        let transcriber = FakeTranscriber(); transcriber.texts = ["one", "two"]
        let session = makeSession()
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.periodicFlush()   // "one", then 2.5 s of quiet pending

        session.stop(); session.reset()   // bypasses stopRecording, which would settle the pause
        coord.startRecording(targetApp: nil)
        // A first append ignores its pause; a non-empty transcript makes the
        // inherited pause, if any, observable.
        session.setTranscript("seed")
        await coord.periodicFlush()   // continuous speech: no quiet of its own

        XCTAssertEqual(session.currentSession?.transcript, "seed two")
    }

    func test_pause_carries_into_the_stop_tail() async {
        let transcript = await transcriptAfterFlushes(
            [makeTone([(4.0, 0.08), (2.5, 0)])], texts: ["one", "two"],
            extraTail: makeTone([(3.0, 0.08)]))
        XCTAssertEqual(transcript, "one\n\ntwo")
    }
}
