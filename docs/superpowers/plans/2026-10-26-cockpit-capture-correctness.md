# Cockpit capture correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stopping a cockpit recording never loses speech, paragraph breaks appear only at measured pauses, cockpit inserts reach the last app that is not VoxFlow (verified against PID reuse), and the shipped chains act on the transcript.

**Architecture:** Keep the stop/restart chunking. Make stop single-flight with an ordered drain (cut at the keypress, await the in-flight flush, transcribe the tail), bind all late work to the recording's session id, and measure pauses from each chunk's own 20 ms frame RMS. Track the last external app from NSWorkspace activations and verify it by bundle ID plus launch date at ⌘R and at insert.

**Tech Stack:** Swift 6.2 (strict concurrency, `@MainActor` coordinators), SwiftUI/AppKit, XCTest via `swift test`.

**Spec:** `docs/superpowers/specs/2026-10-26-cockpit-capture-correctness-design.md` (revision 3, commit 7518dc1).

## Global Constraints

- Swift 6 strict concurrency: no new warnings; coordinators stay `@MainActor`.
- Tests use fakes and temporary directories only. Never touch `~/Library/Application Support/VoxFlow`, `~/Library/Logs/VoxFlow`, or port 8765.
- Tests are deterministic: continuations and `Task.yield()` loops, never `Task.sleep` in test code. Production deferral steps may be configured to 1 ms in tests.
- No new user-facing strings. The interruption marker keeps its wording: `[recording interrupted — <reason>]`.
- Do not change `FocusContextMonitor`, `SmartSpacing`, `CapturedAudio.leadingSilenceSeconds`, `state.focusTarget`, or quick-dictation targeting.
- Never read `NSWorkspace.shared.frontmostApplication` at insert time. Reading it at app launch and at cockpit open is allowed.
- Exact values: frame size 20 ms; `p95 < CapturedAudio.silenceFloor * 3` means whole chunk quiet; threshold `max(CapturedAudio.silenceFloor * 1.5, 0.3 * p95)`; `LongFormSessionService.paragraphBreakPause = 2.0`; rejected-audio reason `interrupted_tail`.
- New prose (comments, docs, commit messages) uses no em-dashes; the marker string keeps its existing one.
- Commit locally on `feature/cockpit-capture-correctness`. Never push. End every commit message with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Test command: `swift test --filter VoxFlowAppTests.<ClassName>` for a class, `swift test` for the suite, run from the worktree root.

## Review Focus

1. **Device change while stopping.** `AudioCaptureService.stopCapture()` throws `deviceChanged` *before* it stops the engine, so a single failed stop leaves the mic hot and the buffered tail unread. Expected: the engine still gets stopped and the tail kept. Test in Task 3 (`test_stop_with_device_change_retries_and_keeps_tail`).
2. **Third consecutive failure during the stop's await.** The tail the stop already took must not vanish when the awaited flush ends the session. Expected: it is kept as an `interrupted_tail` clip. Test in Task 3 (`test_interruption_during_stop_retains_taken_tail`).
3. **A short word after a long pause inside one chunk.** The chunk's p95 is room noise, so `quietThreshold` is nil, yet it produced text. Expected: no spurious break before the next chunk. Test in Task 4 (`test_short_word_after_long_quiet_does_not_break_next_chunk`).
4. **⌘↩ pressed twice while recording.** Both presses would drain, then both would insert. Expected: one insert. Test in Task 5 (`test_concurrent_inserts_during_recording_insert_once`).
5. **Launch date after an ISO8601 round-trip.** Sessions persist with 1 s date resolution, so an exact launch-date comparison would reject the right app. Expected: a sub-second difference still verifies. Test in Task 6 (`test_resolveTarget_tolerates_subsecond_launch_date_difference`).

## Plan rulings (gaps in the spec, decided here)

- **R1. SUPERSEDED by R1a (below).** Its premise was wrong: `AudioCaptureService.handleConfigurationChange` already stops the engine before `stopCapture` throws `deviceChanged`. Original text: **`captureRunning` and failed stops.** The flag clears after a stop that returns audio or throws `AudioCaptureError.captureNotRunning`. Any other stop error leaves it set, because `AudioCaptureService` throws `deviceChanged` before stopping the engine. `stopEngine()` (below) retries once in that case. Cost if wrong: one extra harmless `captureNotRunning` throw.
- **R1a. `captureRunning` clears after any stop attempt, with no retry** (the spec's original rule). Device-change audio is salvaged through an additive seam, `AudioCapturing.takeInvalidatedAudio() -> CapturedAudio?` (default nil): `AudioCaptureService` snapshots the buffer at invalidation, `startCapture` clears it, and the take is one-shot. `stopEngine()` and `endSessionAfterInterruption` use it. `stopCapture`'s throwing behavior is unchanged. Decided during Task 3 review; cost if wrong: one buffered clip held in memory until the next start.
- **R2. Audit S12 test changes.** `test_flushNow_restart_failure_stops_capture_before_ending_session` asserted a second stop on an engine whose restart failed. `startCapture` already removes its own tap when `engine.start()` throws, so that stop only threw `captureNotRunning`. The test now asserts exactly one stop. Cost if wrong: a leaked tap, which the next `startCapture` removes anyway (`removeTap` precedes `installTap`).
- **R3. Fallback threshold for text-bearing chunks.** The spec defines `leadingQuietSeconds` for appended text but not the threshold when `quietThreshold` is nil. Such a chunk uses `CapturedAudio.silenceFloor * 3` instead. Cost if wrong: a missed break in a near-silent chunk, which is the spec's preferred failure.
- **R4. `force` leaves `flushNow`.** `flushNow()` becomes the periodic cut only. The stop sequence transcribes its tail with `transcribeAndAppend(_:force: true)`. Existing callers of `flushNow(force: true)` move to `flushNow()`; with the fake's nil tail energy the behavior is identical.
- **R5. `ExternalAppTracker` is a plain `Sendable` struct**, not `@MainActor`. It is pure; its owner (`AppCoordinator`) is main-actor. Cost if wrong: none at runtime.
- **R6. A nil expected bundle ID resolves to no target.** Launch dates match within 1.0 s (Review Focus 5). Cost if wrong: a pre-change recovered session falls back to the clipboard.
- **R7. Inserts are single-flight** (Review Focus 4): `CockpitCoordinator.insertInFlight`.

---

### Task 1: Frame quiet helpers and `CockpitPauseDetector`

**Files:**
- Create: `Sources/VoxFlowApp/Services/CockpitPauseDetector.swift` (an `extension CapturedAudio` with the three helpers, plus `enum CockpitPauseDetector`)
- Create: `Tests/VoxFlowAppTests/AudioTestSupport.swift`
- Create: `Tests/VoxFlowAppTests/CockpitPauseDetectorTests.swift`

**Interfaces:**
- Consumes: `CapturedAudio` (`pcm`, `sampleRate`, `durationSeconds`, `silenceFloor`) in `Sources/VoxFlowApp/Services/AudioCaptureService.swift`.
- Produces:
  - `extension CapturedAudio { func frameRMSValues() -> [Double]; func leadingQuietSeconds(threshold: Double) -> Double; func trailingQuietSeconds(threshold: Double) -> Double }`
  - `enum CockpitPauseDetector { static func quietThreshold(for audio: CapturedAudio) -> Double? }`
  - Test helper (internal, test target): `func makeTone(_ segments: [(seconds: Double, rms: Double)], sampleRate: Double = 16_000) -> CapturedAudio`, which writes samples alternating `+v` / `-v` where `v = Int16((rms * Double(Int16.max)).rounded())`, so each segment's RMS equals `rms`.

- [ ] **Step 1: Write the failing tests** in `CockpitPauseDetectorTests.swift` (plain `XCTestCase`, not main-actor):

```swift
func test_frameRMSValues_uses_20ms_frames_with_partial_last_frame() {
    let audio = makeTone([(seconds: 0.05, rms: 0.08)])   // 800 samples = 320 + 320 + 160
    let frames = audio.frameRMSValues()
    XCTAssertEqual(frames.count, 3)
    for value in frames { XCTAssertEqual(value, 0.08, accuracy: 0.001) }
}
func test_empty_pcm() {
    let audio = CapturedAudio(pcm: Data(), sampleRate: 16_000)
    XCTAssertEqual(audio.frameRMSValues(), [])
    XCTAssertEqual(audio.leadingQuietSeconds(threshold: 0.01), 0)
    XCTAssertEqual(audio.trailingQuietSeconds(threshold: 0.01), 0)
    XCTAssertNil(CockpitPauseDetector.quietThreshold(for: audio))
}
func test_all_quiet_returns_full_duration() {
    let audio = makeTone([(seconds: 1.0, rms: 0.0)])
    XCTAssertNil(CockpitPauseDetector.quietThreshold(for: audio))
    XCTAssertEqual(audio.leadingQuietSeconds(threshold: 0.01), audio.durationSeconds)
    XCTAssertEqual(audio.trailingQuietSeconds(threshold: 0.01), audio.durationSeconds)
}
func test_leading_and_trailing_quiet_are_measured() {
    let audio = makeTone([(seconds: 1.0, rms: 0.0), (seconds: 2.0, rms: 0.08), (seconds: 0.5, rms: 0.0)])
    let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
    XCTAssertEqual(threshold, 0.024, accuracy: 0.0005)
    XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 1.0, accuracy: 0.02)
    XCTAssertEqual(audio.trailingQuietSeconds(threshold: threshold), 0.5, accuracy: 0.02)
}
func test_weak_speech_is_not_quiet() {
    let audio = makeTone([(seconds: 3.0, rms: 0.01)])
    let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
    XCTAssertEqual(threshold, 0.0045, accuracy: 0.0002)
    XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 0)
}
func test_room_noise_inside_normal_speech_is_quiet() {
    let audio = makeTone([(seconds: 1.0, rms: 0.005), (seconds: 2.0, rms: 0.08)])
    let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
    XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 1.0, accuracy: 0.02)
}
func test_pure_noise_chunk_is_entirely_quiet() {
    XCTAssertNil(CockpitPauseDetector.quietThreshold(for: makeTone([(seconds: 2.0, rms: 0.005)])))
}
func test_each_chunk_is_judged_against_its_own_level() {
    let loud = makeTone([(seconds: 2.0, rms: 0.2)])
    let weak = makeTone([(seconds: 2.0, rms: 0.01)])
    let loudThreshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: loud))
    let weakThreshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: weak))
    XCTAssertEqual(loudThreshold, 0.06, accuracy: 0.001)
    XCTAssertEqual(weak.leadingQuietSeconds(threshold: loudThreshold), weak.durationSeconds,
                   "under the loud chunk's level the weak chunk would read as silence")
    XCTAssertEqual(weak.leadingQuietSeconds(threshold: weakThreshold), 0)
}
```

Mark the tests that use `try XCTUnwrap` as `throws`.

- [ ] **Step 2: Run** `swift test --filter VoxFlowAppTests.CockpitPauseDetectorTests`. Expected: build failure (`frameRMSValues` and `CockpitPauseDetector` not defined).

- [ ] **Step 3: Implement the helpers and the detector.**
  - Frame length in samples: `Int((sampleRate * 0.02).rounded())`. `sampleRate <= 0` or empty PCM gives `[]`.
  - Frames start at sample 0. The last partial frame contributes its own RMS and its actual duration (`samples / sampleRate`).
  - The quiet helpers sum the durations of consecutive frames with RMS `< threshold` from their end. They return exactly `durationSeconds` when every frame is quiet, and 0 when empty.
  - `quietThreshold`: nil when there are no frames. Otherwise take p95 by nearest rank over the unweighted frame values: `sorted[min(n - 1, max(0, Int((0.95 * Double(n)).rounded(.up)) - 1))]`. Return nil when `p95 < CapturedAudio.silenceFloor * 3`, otherwise `max(CapturedAudio.silenceFloor * 1.5, 0.3 * p95)`.

- [ ] **Step 4: Run** the same filter. Expected: 8 tests pass.

- [ ] **Step 5: Commit** `git commit -m "Add frame quiet helpers and the per-chunk pause detector"` (with the trailer).

---

### Task 2: `ChunkJoiner`, measured-pause `appendChunk`, and the interruption marker

**Files:**
- Create: `Sources/VoxFlowApp/Services/ChunkJoiner.swift`
- Modify: `Sources/VoxFlowApp/Services/LongFormSessionService.swift` (type doc comment lines 14-20, `lastChunkAt` line 36, `paragraphBreakSilence` line 39, `start` line 65, `appendChunk` lines 80-93, `reset` line 126)
- Modify: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift:216` and `:247` (call sites only)
- Create: `Tests/VoxFlowAppTests/LongFormSessionTestSupport.swift`
- Create: `Tests/VoxFlowAppTests/ChunkJoinerTests.swift`
- Modify: `Tests/VoxFlowAppTests/LongFormSessionServiceTests.swift` (replace the tests at lines 81-113; update other `appendChunk` calls)
- Modify: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift` (every `sessionService.appendChunk(...)` call)

**Interfaces:**
- Produces:
  - `enum ChunkJoiner { static func join(_ previous: String, _ next: String) -> String }`
  - `LongFormSessionService.paragraphBreakPause: TimeInterval = 2.0` (`static let`, internal)
  - `func appendChunk(_ chunk: String, pauseBefore: TimeInterval, sessionID: UUID)`
  - `func appendInterruptionMarker(_ reason: String, sessionID: UUID)`
  - Test helper: `extension LongFormSessionService { func appendTestChunk(_ text: String, pauseBefore: TimeInterval = 0) }`. It appends to `currentSession?.id` and does nothing without a session.

- [ ] **Step 1: Write the failing `ChunkJoinerTests`** (one assertion per spec vector, plus edges):

```swift
XCTAssertEqual(ChunkJoiner.join("world.", "Second"), "world. Second")
XCTAssertEqual(ChunkJoiner.join("He said", "“hello”"), "He said “hello”")
XCTAssertEqual(ChunkJoiner.join("(note", ")"), "(note)")
XCTAssertEqual(ChunkJoiner.join("Hello", ","), "Hello,")
XCTAssertEqual(ChunkJoiner.join("x\n\n", "y"), "x\n\ny")
XCTAssertEqual(ChunkJoiner.join("rate", "%"), "rate%")
XCTAssertEqual(ChunkJoiner.join("3", "14"), "3 14")          // known limitation, documented
XCTAssertEqual(ChunkJoiner.join("", "Start"), "Start")
XCTAssertEqual(ChunkJoiner.join("open “", "quoted"), "open “quoted")
XCTAssertEqual(ChunkJoiner.join("¿", "Qué"), "¿Qué")
XCTAssertEqual(ChunkJoiner.join("wait", "…"), "wait…")
XCTAssertEqual(ChunkJoiner.join("say", "\"hi\""), "say \"hi\"")
XCTAssertEqual(ChunkJoiner.join("done", ""), "done")         // empty next adds nothing
```

- [ ] **Step 2: Write the failing `LongFormSessionServiceTests`.** Delete `test_silence_longer_than_4s_inserts_paragraph_break`, `test_silence_under_4s_no_paragraph_break`, and `test_paragraph_break_not_duplicated`. Add:
  - `test_first_chunk_becomes_transcript`: `"hello"` with pause 5.0 gives `"hello"`.
  - `test_pause_just_under_threshold_joins`: `"first."` then `"second."` with pauseBefore 1.9 gives `"first. second."`.
  - `test_pause_at_threshold_breaks`: the same pair with 2.0 gives `"first.\n\nsecond."`.
  - `test_break_never_adds_more_than_one_blank_line`: `setTranscript("a\n\n")` while recording, then `"b"` at 3.0, gives `"a\n\nb"`.
  - `test_mismatched_session_id_is_ignored`: `appendChunk("x", pauseBefore: 0, sessionID: UUID())` leaves the transcript `""`.
  - `test_appendChunk_ignored_when_idle`: rewritten with a random UUID; the transcript stays nil.
  - `test_marker_on_empty_transcript`: gives `"[recording interrupted — device]"`.
  - `test_marker_after_text`: `"a"` gives `"a\n\n[recording interrupted — device]"`.
  - `test_marker_after_existing_blank_line_yields_one_blank_line`: `"a\n\n"` gives `"a\n\n[recording interrupted — device]"`.
  - `test_marker_with_mismatched_session_id_is_ignored`.

  Change every other test-file call of `appendChunk("…")` (here and in `CockpitCoordinatorTests.swift`) to `appendTestChunk("…")`.

- [ ] **Step 3: Run** `swift test --filter "VoxFlowAppTests.ChunkJoinerTests|VoxFlowAppTests.LongFormSessionServiceTests|VoxFlowAppTests.CockpitCoordinatorTests"`. Expected: build failure on the new API.

- [ ] **Step 4: Implement.**
  - `ChunkJoiner.join` returns `previous + next` with no separator when `next` is empty, or when `previous` is empty or its last character is whitespace or a newline. It also omits the separator when `previous` ends in one of `( [ { “ ‘ « ¿ ¡`, or `next` starts with one of `. , ; : ! ? ) ] } ” ’ » … %`. Otherwise it inserts exactly one space.
  - `appendChunk`:
    - Guard `case .recording = state` and `sessionID == currentSession?.id`.
    - An empty transcript gives the chunk as the transcript.
    - `pauseBefore >= Self.paragraphBreakPause`: trim trailing whitespace and newlines, append `"\n\n"`, then the chunk.
    - Otherwise use `ChunkJoiner.join`.
    - Always set `updatedAt = clock.currentTime()`.
  - `appendInterruptionMarker` uses the same guards. It trims trailing whitespace and newlines, appends `"\n\n"` only when the result is non-empty, then appends `"[recording interrupted — \(reason)]"`.
  - Remove `lastChunkAt` and `paragraphBreakSilence`.
  - Rewrite the type doc comment's pause sentence: breaks come from measured pauses passed by the capture coordinator, and `paragraphBreakPause` is 2 s.
  - Coordinator call sites, interim until Task 3 binds the id:
    - Line 216: `if let id = session.currentSession?.id { session.appendChunk(corrected, pauseBefore: 0, sessionID: id) }`
    - Line 247: the same pattern with `session.appendInterruptionMarker(reason, sessionID: id)`

- [ ] **Step 5: Run** the Step 3 filter, then `swift test --filter VoxFlowAppTests.CockpitCaptureCoordinatorTests`. Expected: all pass. The marker test in the capture suite still sees `"…\n\n[recording interrupted — …]"`.

- [ ] **Step 6: Commit** `"Join chunks by measured pause and punctuation, not wall-clock time"`.

---

### Task 3: Safe drain, session binding, and interruption tail retention

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift` (stored state near lines 25-42, `startRecording` 92-107, `stopRecording` 109-115, `flushNow` 121-166, `transcribeAndAppend` 168-237, `endSessionAfterInterruption` 243-249)
- Modify: `Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift` (fakes at lines 5-55; migrate `flushNow(force: true)` calls; rewrite the S12 test at lines 337-356)

**Interfaces:**
- Consumes: `appendChunk(_:pauseBefore:sessionID:)` and `appendInterruptionMarker(_:sessionID:)` (Task 2).
- Produces:
  - `func periodicFlush() async`, internal. Runs one `flushNow()` inside `flushTask` and awaits it. The loop and the tests call it.
  - `func flushNow() async` with no `force` parameter (ruling R4).
  - `func stopRecording() async`, now single-flight.
  - Private state: `stopTask`, `flushTask`, `captureRunning`, `stopRequested`, `recordingSessionID: UUID?`.
  - Private helpers: `stopEngine() -> CapturedAudio?` and `retainInterruptedAudio(_ pcm: Data, sampleRate: Double)`.
  - `transcribeAndAppend(_:force:)` keeps its signature. Task 4 adds pause accounting inside it.

- [ ] **Step 1: Upgrade the fakes** (test file only).
  - `FakeCapture`:
    - Add `var queue: [CapturedAudio] = []`. Each `stopCapture()` serves `queue.removeFirst()`, or `nextAudio` when the queue is empty.
    - Add `private(set) var isRunning = false`, set true by a non-failing `startCapture`. `failNextStart` throws and leaves the flag unchanged.
    - `stopCapture()` on `!isRunning` calls `XCTFail("stopCapture on a stopped engine")` and throws `AudioCaptureError.captureNotRunning`.
    - `failNextStop` throws `deviceChanged` and leaves `isRunning` true, matching `AudioCaptureService`. A successful stop sets it false.
    - Add `var restartCount: Int { max(0, startCount - 1) }`.
  - `FakeTranscriber`:
    - Make it `@MainActor` (an async requirement accepts an isolated witness). If the compiler rejects that, keep it nonisolated and guard its state with an `OSAllocatedUnfairLock`.
    - Add `var texts: [String]` and `var confidences: [Double]`, served per call, falling back to `nextText` and 0.9.
    - Add `var holdCalls = 0`: while positive, each call decrements it and suspends on a `CheckedContinuation<Void, Never>` stored in `held`. A resumed call then proceeds as usual: the failure check, then recording `receivedPCMCounts`, then the response.
    - Add `func releaseNext()`, `var heldCount: Int`, and `func waitUntilHeld(_ n: Int) async`, a `Task.yield()` loop.
  - Coordinator tests that use deferral pass `flushDeferralStepNs: 1_000_000`.

- [ ] **Step 2: Write the failing drain tests.** `a` and `b` are distinct non-silent `makeAudio` buffers with 8000 and 4000 samples.
  - `test_stop_during_inflight_transcription_appends_chunk_then_tail`:

    ```swift
    capture.queue = [a, b]; transcriber.texts = ["first part", "second part"]; transcriber.holdCalls = 1
    coord.startRecording(targetApp: nil)
    let flush = Task { await coord.periodicFlush() }
    await transcriber.waitUntilHeld(1)
    let stop = Task { await coord.stopRecording() }
    while capture.stopCount < 2 { await Task.yield() }   // the tail is cut at the keypress
    transcriber.releaseNext()
    await stop.value; await flush.value
    XCTAssertEqual(session.currentSession?.transcript, "first part second part")
    XCTAssertEqual(session.state, .reviewing)
    XCTAssertEqual(transcriber.receivedPCMCounts, [16_000, 8_000])
    ```

  - `test_tail_is_cut_at_the_keypress`: queue `[a, b, c]`, same choreography. `c` is never served (`capture.queue.count == 1`), `stopCount == 2`, and `restartCount == 1`.
  - `test_double_stop_appends_tail_once_and_never_restarts`: two concurrent `stopRecording()` tasks during a held flush both complete. The transcript contains `"second part"` exactly once, and `restartCount == 1`.
  - `test_stop_during_flush_deferral_abandons_the_cut`:
    - Setup: `tailRMSValue = 0.05`, `maxFlushDeferralNs: 10_000_000_000`, `queue = [b]`.
    - Start `periodicFlush()`, wait until `tailRMSConsults >= 1`, then stop.
    - Assert `receivedPCMCounts == [8_000]`, `stopCount == 1`, `restartCount == 0`.
  - `test_stop_after_restart_failure_issues_no_stop`: `failNextStart = true`, then `await coord.periodicFlush()` (the session ends), then `await coord.stopRecording()`. Assert `stopCount == 1`; the fake fails the test on a stop-while-stopped.
  - `test_start_is_refused_while_a_stop_drains`: during a held flush with a pending stop, call `session.reset()` and then `coord.startRecording(targetApp: nil)`. Assert `startCount` is unchanged. Release and await.
  - `test_stop_with_device_change_retries_and_keeps_tail` (Review Focus 1): `queue = [b]` and `failNextStop = true`, then stop. Assert `stopCount == 2`, `!capture.isRunning`, the transcript contains the tail text, and the state is `.reviewing`.
  - `test_third_failure_interruption_retains_buffered_tail`:
    - Setup: `RejectedAudioStore(directory: tmp, maxClips: 8, enabled: true)` and `failuresRemaining = 3`.
    - Three `periodicFlush()` calls.
    - Assert the directory holds 3 files containing `transcription_error` and 1 containing `interrupted_tail`, and the transcript ends with `"[recording interrupted — transcription failing repeatedly — audio clips kept]"`.
  - `test_interruption_during_stop_retains_taken_tail` (Review Focus 2):
    - Setup: `failuresRemaining = 3`. Two failing flushes, then a held third, then a stop, then release.
    - Assert one `interrupted_tail` clip from the stop's tail, and the state is `.reviewing`.
  - `test_late_chunk_from_old_session_is_ignored`: hold a flush, then call `session.stop()`, `session.reset()`, and `session.start()` directly so the ids differ. Release and await. The new session's transcript stays `""`.
  - The next two tests leave coordinator state stale by ending recording 1 with `session.stop()` and `session.reset()` called directly, bypassing `stopRecording()`. A normal stop now merges the carry, so this is the only way to reach the reset.
  - `test_new_recording_starts_with_empty_carry`: recording 1's flush serves a 4000-sample non-silent chunk, which is carried. Recording 2's first flush succeeds, and `receivedPCMCounts.last` equals that chunk's bytes alone.
  - `test_new_recording_starts_with_zero_failure_count`: recording 1 has two failing flushes. Recording 2's first flush fails, and the state is still `.recording`.
  - Rewrite the S12 test (ruling R2): `stopCount == 1`, and the session is not `.recording`.
  - Migrate every `flushNow(force: true)` to `flushNow()`.

- [ ] **Step 3: Run** `swift test --filter VoxFlowAppTests.CockpitCaptureCoordinatorTests`. Expected: the new tests fail (no `periodicFlush`; the stop drops the tail; double-stop races).

- [ ] **Step 4: Implement**, following spec Decision 1. These orderings are load-bearing:

```swift
/// Stops the engine when it may be running and returns what it buffered.
/// AudioCaptureService throws deviceChanged before it stops the engine, so
/// any failure other than captureNotRunning gets one retry, which stops it.
private func stopEngine() -> CapturedAudio? {
    guard captureRunning else { return nil }
    defer { captureRunning = false }
    do { return try capture.stopCapture() }
    catch AudioCaptureError.captureNotRunning { return nil }
    catch { return try? capture.stopCapture() }
}

private func performStop() async {
    guard case .recording = session.state, let id = recordingSessionID,
          session.currentSession?.id == id else { return }
    stopRequested = true
    loopTask?.cancel(); loopTask = nil
    let tail = stopEngine()                       // the cutoff
    await flushTask?.value
    guard case .recording = session.state, session.currentSession?.id == id else {
        if let tail { retainInterruptedAudio(tail.pcm, sampleRate: tail.sampleRate) }
        return
    }
    await transcribeAndAppend(
        tail ?? CapturedAudio(pcm: Data(), sampleRate: AudioCaptureService.targetSampleRate),
        force: true)                              // merges any carryPCM
    guard session.currentSession?.id == id else { return }
    session.stop()
}
```

  - `stopRecording()`:
    - If `stopTask` exists, await it and return.
    - Otherwise store `Task { await self.performStop() }` in `stopTask`, await it, and set `stopTask = nil`.
  - `startRecording`:
    - Guard `stopTask == nil` and `.idle`.
    - Reset `carryPCM`, `consecutiveTranscriptionFailures`, `stopRequested`, and `captureRunning`.
    - Set `recordingSessionID = session.currentSession?.id` after `session.start`.
    - Set `captureRunning = true` only after `startCapture` succeeds. On failure, clear `recordingSessionID`.
    - Cancel any stale `loopTask` before creating the new one.
    - The loop checks `!Task.isCancelled` after its sleep, before `periodicFlush()`.
  - `flushNow()`:
    - Guard `!isFlushing`, `!stopRequested`, `captureRunning`, and `.recording`.
    - After each deferral sleep, re-check `!stopRequested` and `.recording`.
    - The cut sets `captureRunning = false` on success. On `captureNotRunning` it also clears the flag, then calls `endSessionAfterInterruption`. Any other error leaves the flag set (ruling R1) and calls `endSessionAfterInterruption`.
    - Restart only when `!stopRequested`, setting `captureRunning = true` on success.
  - `transcribeAndAppend`:
    - Capture `let id = recordingSessionID` before any await, and append with `sessionID: id`.
    - After the await, if `id != recordingSessionID`, skip the failure counting and the end-session call. On error it still retains the clip.
  - `endSessionAfterInterruption`:
    - Guard `.recording` and `recordingSessionID == currentSession?.id`.
    - Cancel the loop.
    - Concatenate `carryPCM`, then `stopEngine()?.pcm`. Use the sample rate of the stopped audio, or `AudioCaptureService.targetSampleRate` when there is only carry.
    - Clear `carryPCM`, call `retainInterruptedAudio`, `appendInterruptionMarker(reason, sessionID:)`, and `session.stop()`.
  - `retainInterruptedAudio`: skips empty or `isSilent` PCM. Otherwise it stores with reason `"interrupted_tail"` and writes `audit?.recordRejection(text: "", reason: "interrupted_tail", confidence: 0, durationSeconds:, source: "cockpit_chunk", audioFile:)`.
  - Update the comments that describe the old forced flush.

- [ ] **Step 5: Run** the filter. Expected: all tests in the class pass, with no XCTFail from the fake.

- [ ] **Step 6: Commit** `"Drain cockpit stops in order and bind late work to its session"`.

---

### Task 4: Pause accounting across chunk boundaries

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift` (`transcribeAndAppend`, `startRecording` reset)
- Modify: `Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CockpitPauseDetector.quietThreshold(for:)` and the three quiet helpers (Task 1), `makeTone` (Task 1), `appendChunk(_:pauseBefore:sessionID:)` (Task 2), and the drain structure (Task 3).
- Produces: `private var pendingPause: TimeInterval`, reset to 0 in `startRecording`.

- [ ] **Step 1: Write the failing tests.** Each queues `makeTone` chunks into `FakeCapture`, scripts `texts`, and calls `periodicFlush()` once per chunk.
  - `test_continuous_speech_across_three_flushes_is_one_paragraph`: three `[(5.0, 0.08)]` chunks with texts `one`, `two`, `three` give `"one two three"`.
  - `test_quiet_span_across_boundary_breaks_once`: `[(4.0, 0.08), (1.2, 0)]`, then `[(1.0, 0), (3.0, 0.08)]`, give `"one\n\ntwo"`.
  - `test_short_quiet_span_across_boundary_joins`: trailing 0.9 plus leading 0.9 gives `"one two"`.
  - `test_all_quiet_window_between_speech_breaks`: speech `one`, then `[(5.0, 0.004)]` with text `""`, then speech `three`, gives `"one\n\nthree"`.
  - `test_gate_rejected_speech_chunk_does_not_create_break`:
    - Chunks: `[(4.0, 0.08), (1.5, 0)]` with text `one`; then `[(5.0, 0.08)]` with text `um` at confidence 0.05 (rejected as lowConfidence); then `[(1.0, 0), (4.0, 0.08)]` with text `three`.
    - Expected: `"one three"`.
  - `test_carried_subminimum_merge_counts_once`:
    - Chunks: `[(4.0, 0.08), (1.8, 0)]` with text `one`; then a carry `[(0.15, 0), (0.1, 0.08)]` (8000 bytes, below 9600); then `[(0.7, 0), (4.0, 0.08)]` with text `three`.
    - Expected: `"one three"` (1.8 + 0.15 < 2.0; double-counting the carry would break).
  - `test_short_word_after_long_quiet_does_not_break_next_chunk` (Review Focus 3, ruling R3): `[(4.8, 0.004), (0.2, 0.08)]` with text `hello`, then `[(5.0, 0.08)]` with text `world`, gives `"hello world"`.
  - `test_pause_carries_into_the_stop_tail`: speech `one` with trailing 2.5 s quiet, then the stop's tail `[(3.0, 0.08)]` with text `two`, gives `"one\n\ntwo"`.

- [ ] **Step 2: Run** the filter. Expected: the break and join tests fail, because every append still passes `pauseBefore: 0`.

- [ ] **Step 3: Implement**, inside `transcribeAndAppend`, after the carry merge:
  - The carried sub-minimum branch returns with no change.
  - Compute `let threshold = CockpitPauseDetector.quietThreshold(for: merged)` and `wholeQuiet`, which is true when `threshold` is nil or every frame RMS is below it.
  - **Text appended:**
    - Let `t = threshold ?? CapturedAudio.silenceFloor * 3` (ruling R3).
    - Set `pauseBefore = pendingPause + merged.leadingQuietSeconds(threshold: t)`, then `pendingPause = merged.trailingQuietSeconds(threshold: t)`.
  - **No text** (silent drop, empty text, gate rejection, transcription error):
    - Whole quiet: `pendingPause += merged.durationSeconds`.
    - Otherwise: `pendingPause = merged.trailingQuietSeconds(threshold: threshold!)`.
  - The restart gap is never added.

- [ ] **Step 4: Run** the filter. Expected: all tests in the class pass, including Task 3's.

- [ ] **Step 5: Commit** `"Break paragraphs only at measured pauses that span a chunk boundary"`.

---

### Task 5: ⌘↩ drains before inserting

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift` (properties near line 26; `insertIntoTarget` at line 213)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (wiring next to `cockpit.onCockpitOpened`, about line 301)
- Modify: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CockpitCaptureCoordinator.stopRecording()` (Task 3) and `appendTestChunk` (Task 2).
- Produces:
  - `var drainRecording: (@MainActor () async -> Void)?` on `CockpitCoordinator`.
  - `private var insertInFlight = false` (ruling R7).

- [ ] **Step 1: Write the failing tests**, modeled on `test_insert_failure_keeps_cockpit_open_and_session_intact`. Use a `RecordingInsertService: TextInserting` that records texts and returns success with method `.simulatedPaste`, so `TextInsertionCoordinator` never writes the system pasteboard:
  - `test_insert_during_recording_drains_then_inserts_complete_transcript`:
    - `start()`, then `appendTestChunk("first part")`.
    - `coord.drainRecording = { sessionService.appendTestChunk("tail words"); sessionService.stop() }`.
    - `await coord.insertIntoTarget()`.
    - Assert the inserted texts equal `["first part tail words"]` and the state is `.idle` (reset on success).
  - `test_insert_during_recording_without_drain_inserts_nothing`: `drainRecording` is nil. Assert no insert call and the session is still `.recording`.
  - `test_concurrent_inserts_during_recording_insert_once` (Review Focus 4):
    - `drainRecording` suspends on a continuation, then stops the session.
    - Start two `Task { await coord.insertIntoTarget() }`.
    - Resume once the continuation is captured, and await both.
    - Assert exactly one insert call.

- [ ] **Step 2: Run** `swift test --filter VoxFlowAppTests.CockpitCoordinatorTests`. Expected: the three tests fail.

- [ ] **Step 3: Implement.**
  - `insertIntoTarget` starts with the single-flight guard: `guard !insertInFlight`, set it, and clear it in a `defer`.
  - When the state is `.recording`, `await drainRecording?()`.
  - Then `guard case .reviewing = sessionService.state, let session = sessionService.currentSession` before both the Notion and AX branches.
  - `AppCoordinator`: `cockpit.drainRecording = { [weak self] in await self?.cockpitCapture.stopRecording() }`.

- [ ] **Step 4: Run** the filter. Expected: all pass.

- [ ] **Step 5: Commit** `"Drain an active recording before a cockpit insert"`.

---

### Task 6: Last external app target, verified at ⌘R and at insert

**Files:**
- Create: `Sources/VoxFlowApp/Services/ExternalAppTracker.swift`
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift:611-631` (`FocusTargetSnapshot` gains `var launchDate: Date? = nil` after `processIdentifier`)
- Modify: `Sources/VoxFlowApp/State/AppState.swift` (`@Published var lastExternalApp: ExternalAppIdentity?` beside `focusTarget`, line 14)
- Modify: `Sources/VoxFlowApp/Services/CockpitCoordinator.swift` (`recordingTargetProvider`, `recordingTarget()`, and target resolution in `insertIntoTarget`, replacing lines 237-243)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift`:
  - The `chainExecutor` `frozenTarget` closure, lines 182-185.
  - Tracker state plus `startExternalAppTracking()`, called right after `startFocusMonitoring()` at line 257.
  - The `onCockpitOpened` wiring at line 301, which seeds before the warmup.
  - The `recordingTargetProvider` wiring.
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift:206` (`startRecording(targetApp: coordinator.recordingTarget())`)
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift:37-48`
- Modify: `CLAUDE.md` (the Cockpit section, line 120) and `CHANGELOG.md` (`[Unreleased]` → `### Fixed`)
- Create: `Tests/VoxFlowAppTests/ExternalAppTrackerTests.swift`
- Modify: `Tests/VoxFlowAppTests/CockpitCoordinatorTests.swift`

**Interfaces:**
- Produces:

```swift
struct ExternalAppIdentity: Equatable, Sendable {
    let pid: Int32; let bundleID: String; let name: String?; let launchDate: Date
    var targetSnapshot: FocusTargetSnapshot { get }   // no text-input flags, role nil
}
struct ExternalAppTracker: Sendable {
    typealias RunningAppFacts = (bundleID: String?, launchDate: Date?, terminated: Bool)
    private(set) var current: ExternalAppIdentity?
    mutating func record(pid: Int32, bundleID: String?, name: String?, launchDate: Date?, ownPID: Int32)
    func currentVerified(lookup: (Int32) -> RunningAppFacts?) -> ExternalAppIdentity?
    static func resolveTarget(pid: Int32?, expectedBundleID: String?, expectedLaunchDate: Date?,
                              lookup: (Int32) -> RunningAppFacts?) -> Int32?
    static func liveLookup(_ pid: Int32) -> RunningAppFacts?                    // NSRunningApplication
    @MainActor static func liveRunningApp(for snapshot: FocusTargetSnapshot?) -> NSRunningApplication?
}
// CockpitCoordinator
var recordingTargetProvider: (@MainActor () -> FocusTargetSnapshot?)?
func recordingTarget() -> FocusTargetSnapshot?   // provider's value, nil without a provider
```

- [ ] **Step 1: Write the failing `ExternalAppTrackerTests`** (a fake lookup over a dictionary `[Int32: RunningAppFacts]`, with `let t0 = Date(timeIntervalSince1970: 1_800_000_000)`):
  - `test_record_ignores_own_pid_nonpositive_pid_nil_bundle_and_nil_launch_date`: each of `ownPID`, `0`, `-1`, `bundleID: nil`, and `launchDate: nil` leaves `current` nil.
  - `test_record_keeps_latest_external_app`: recording Slack and then Notes gives `current?.bundleID == "com.apple.Notes"`. A later VoxFlow (own pid) activation keeps Notes.
  - `test_resolveTarget_matching_bundle_and_launch_date_resolves`: returns the pid.
  - `test_resolveTarget_reused_pid_with_other_bundle_is_nil`.
  - `test_resolveTarget_relaunch_on_reused_pid_is_nil`: same bundle, launch date `t0 + 5`.
  - `test_resolveTarget_terminated_app_is_nil`.
  - `test_resolveTarget_nil_pid_is_nil` and `test_resolveTarget_nil_expected_bundle_is_nil` (ruling R6).
  - `test_resolveTarget_nil_expected_launch_date_checks_bundle_only`.
  - `test_resolveTarget_tolerates_subsecond_launch_date_difference` (Review Focus 5): `t0 + 0.4` resolves.
  - `test_currentVerified_returns_identity_only_when_running_and_matching`: a match returns it; a relaunch or a missing lookup returns nil.
  - `test_targetSnapshot_carries_identity_without_text_input_flags`: pid, bundle, name, and launch date are set; both flags are false; `role` is nil.
  - `test_snapshot_without_launchDate_key_still_decodes`: decode the JSON for `FocusTargetSnapshot.unavailable` encoded before the field existed (build it as a literal string without the key). `launchDate` is nil.

  Add to `CockpitCoordinatorTests`:
  - `test_recordingTarget_uses_provider`
  - `test_recordingTarget_without_provider_is_nil`

- [ ] **Step 2: Run** `swift test --filter "VoxFlowAppTests.ExternalAppTrackerTests|VoxFlowAppTests.CockpitCoordinatorTests"`. Expected: build failure.

- [ ] **Step 3: Implement.**
  - `record` ignores `pid <= 0`, `pid == ownPID`, a nil bundle ID, and a nil launch date; otherwise it replaces `current`.
  - `resolveTarget` returns nil for any of:
    - a nil pid or a nil expected bundle;
    - a missing lookup or a terminated app;
    - a bundle mismatch;
    - a non-nil expected launch date when the actual date is nil or `abs(actual.timeIntervalSince(expected)) > 1.0`.

    Otherwise it returns the pid.
  - `currentVerified` is `resolveTarget` applied to `current`.
  - `liveRunningApp(for:)` resolves the snapshot's pid, bundle, and launch date with `liveLookup`, then builds `NSRunningApplication(processIdentifier:)`.
  - `insertIntoTarget` and the chain `frozenTarget` closure both call `ExternalAppTracker.liveRunningApp(for: …targetApp)`. Rewrite the old PID-only comment to say why both checks exist.
  - `AppCoordinator`:
    - Fields: `private var externalAppTracker = ExternalAppTracker()` and `private var workspaceActivationObserver: NSObjectProtocol?`.
    - `recordExternalApp(_ app: NSRunningApplication?)` passes `ProcessInfo.processInfo.processIdentifier` as `ownPID` and mirrors `state.lastExternalApp = externalAppTracker.current`.
    - Observe `NSWorkspace.didActivateApplicationNotification` on `NSWorkspace.shared.notificationCenter` with `queue: .main`. Extract `processIdentifier`, `bundleIdentifier`, `localizedName`, and `launchDate` before `MainActor.assumeIsolated`, so no non-Sendable value crosses.
    - Seed once from `frontmostApplication` in `startExternalAppTracking()`, and again in `onCockpitOpened`, before `scheduleRuntimeWarmupIfNeeded()`.
    - Wire `cockpit.recordingTargetProvider = { [weak self] in self?.externalAppTracker.currentVerified(lookup: ExternalAppTracker.liveLookup)?.targetSnapshot }`.
  - Side panel: with a session target, show it as today. With no current session and a `state.lastExternalApp?.name`, show that name with the existing `"append at cursor"` caption. Otherwise show `"focused app"`.
  - `CLAUDE.md` Cockpit section: replace the `appendChunk(_:)` sentence. The new text says breaks come at measured pauses spanning a chunk boundary (`paragraphBreakPause` 2 s, per-chunk 20 ms frame RMS via `CockpitPauseDetector`); chunks join through `ChunkJoiner`; and ⌘R freezes the last external app from `ExternalAppTracker`, verified by bundle ID and launch date at insert.
  - `CHANGELOG.md` `### Fixed`: one bullet each for:
    - stopping no longer drops the last words, a double ⌘. is safe, and ⌘↩ while recording inserts everything;
    - paragraph breaks only at real pauses, with no glued words;
    - the cockpit inserts into the app you came from and never into a different app that reused its process id.

- [ ] **Step 4: Run** the Step 2 filter, then `swift build`. Expected: the tests pass and the build is clean.

- [ ] **Step 5: Commit** `"Target the last external app and verify it by launch date"`.

---

### Task 7: Chains seed from the transcript

**Files:**
- Modify: `Sources/VoxFlowApp/Services/ChainExecutor.swift` (header comment lines 13-16, `run` line 59, the `.action` case)
- Modify: `Sources/VoxFlowApp/Services/ChainStore.swift:31-33` (the `seedChains` comment)
- Modify: `Tests/VoxFlowAppTests/ChainExecutorTests.swift` (rewrite the test at line 230; move the two methods out of `CallCounter`, lines 379-431)
- Modify: `CHANGELOG.md` (`### Fixed`: one bullet saying the shipped "Memo" and "Action items" chains now run on the transcript)

**Interfaces:**
- Consumes: `ChainStore.seedChains`.
- Produces: the result contract change from spec Decision 4. `finalText` starts as the current transcript.

- [ ] **Step 1: Write the failing tests.**
  - `test_seeded_memo_chain_acts_on_transcript`: build `WorkflowChain(name:, steps: ChainStore.seedChains[0].steps, createdAt:)` with `currentTranscript: { "raw transcript" }`. The backend received `["raw transcript"]`, and the insert call text is the action output.
  - `test_seeded_action_items_chain_acts_on_transcript`: the same with `seedChains[1]`.
  - `test_action_on_empty_transcript_fails_noTranscript_without_backend_call`: `[.action(actionId: .memo)]` with `currentTranscript: { "" }` gives `error == .noTranscript`, `failedStepIndex == 0`, and the backend's received list is empty.
  - Rewrite `test_insert_only_chain_with_empty_text_fails_without_clipboard`:
    - Rename it to `test_insert_only_chain_inserts_transcript`. With `{ "ignored transcript" }` it now inserts `"ignored transcript"` and succeeds.
    - Add `test_insert_only_chain_with_empty_transcript_fails_without_clipboard`, which keeps the old `.insertFailed`, no-clipboard assertions with `{ "" }`.
  - Move `testAppStepsDispatchAndPreserveWorkingText` and `testFailedAppStepStopsChain` onto `ChainExecutorTests`. Capture `performed` through a reference box (the `CallCounter` pattern) to satisfy strict concurrency. Leave `CallCounter` only if something still uses it.

- [ ] **Step 2: Run** `swift test --filter VoxFlowAppTests.ChainExecutorTests`. Expected: the seeded-chain and insert-only tests fail; the relocated tests now run.

- [ ] **Step 3: Implement.**
  - `run` starts with `var workingText = currentTranscript() ?? ""`.
  - The `.action` case starts with `guard !workingText.isEmpty else { return failure(.noTranscript, atIndex: index, workingText: workingText, clipboardFallback: false) }`.
  - Update both comments: chains without a `.capture` act on the current transcript.

- [ ] **Step 4: Run** the filter. Expected: all pass, including the relocated app-step tests. If a relocated test fails on real behavior, fix the code, not the assertion.

- [ ] **Step 5: Commit** `"Seed chains from the current transcript"`.
