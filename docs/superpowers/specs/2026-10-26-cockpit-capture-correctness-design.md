# Cockpit capture correctness — design spec

Source: the 2026-10-26 multi-model review (triage R-02 to R-05, each verified
against the code by an independent pass). User decisions: fix within the
current stop/restart chunking (continuous capture is a later spec);
paragraph breaks at real pauses only; the cockpit targets the most recent app
that is not VoxFlow, frozen at ⌘R. Revision 2 folds in an adversarial Sol 6.1
review of revision 1. The controller verified the claims this revision relies on
(the double-stop race; `insertIntoTarget` ignores session state).

## Measured facts driving this work

- **Stop loses speech (R-02).**
  - `stopRecording` cancels `loopTask` and calls `flushNow(force: true)`. That
    call returns at once on `guard !isFlushing` when a periodic flush is
    mid-transcription.
  - `capture.stopCapture()` then discards the tail PCM, and `session.stop()`
    moves to `.reviewing`, so the late chunk is rejected by `appendChunk`'s
    `guard case .recording`.
  - The periodic flush runs inside `loopTask`, so `loopTask.cancel()` can
    cancel its in-flight transcription.
- **More ways to lose or misplace speech.**
  - Each ⌘. launches `Task { await stopRecording() }`, so two presses run two
    interleaved stops (`CockpitWindowView.swift:209`).
  - `CockpitCoordinator.insertIntoTarget` does not check session state. ⌘↩
    during recording inserts the partial transcript and resets the session
    while capture keeps running.
  - The forced final flush restarts capture before transcribing, and stop then
    discards whatever the restart captured.
  - `endSessionAfterInterruption` stops capture without keeping the audio
    buffered since the last cut.
  - `carryPCM` and `consecutiveTranscriptionFailures` survive into the next
    recording.
- **Paragraph break every 5 s; glued final chunk (R-03).**
  - `appendChunk` breaks on wall-clock time since the previous append
    (`paragraphBreakSilence` 4.0 s). Appends are always more than 5 s apart, so
    every chunk after the first in continuous speech starts a paragraph.
  - Below 4 s it concatenates with no separator, so the forced stop chunk is
    often glued on ("world.Second").
  - The interruption marker carries its own `\n\n`.
- **Cockpit targets itself (R-04).**
  - ⌘R passes `state.focusTarget` from the polled AX snapshot. The cockpit is an
    activating window, so at ⌘R the snapshot is VoxFlow or `.unavailable`.
  - Insert and chains rebuild `NSRunningApplication` from the frozen PID alone
    (`CockpitCoordinator.swift:243`, `AppCoordinator.swift:182`), so a reused
    PID would resolve an unrelated app.
- **Shipped chains always fail (R-05).** `ChainExecutor.run` starts
  `workingText = ""`, and the seeded "Memo" and "Action items" have no
  `.capture`, so step 1 sends an empty transcript (422).
- **Existing quiet tests.**
  - The quiet-boundary flush judges a 300 ms tail against
    `speechFloor * 0.75`.
  - `CapturedAudio.leadingSilenceSeconds` is a per-sample test at
    `silenceFloor`, and room noise defeats it.
  - Neither is a reliable pause detector for weak speakers. VoxFlow supports
    boosting weak input (`AudioGain`), and weak speech near RMS 0.01 sits below
    0.015.
- `SmartSpacing.adjusted` was built for AX insertion. It yields `He said“hello”`
  and `"hello"and`, so it is not a safe chunk joiner.

## Goals

1. Stopping a cockpit recording never loses speech captured before the stop,
   however many times ⌘. is pressed, and ⌘↩ during recording inserts the
   complete transcript.
2. Paragraph breaks appear only at measured pauses that span a chunk boundary.
   Chunks otherwise join with one space, or none before closing punctuation.
3. ⌘↩ and chain inserts go to the most recent app that is not VoxFlow, as of
   ⌘R, and never to a different app that reuses its PID.
4. The shipped chains run their action on the current transcript.

## Non-goals

- Continuous capture or VAD segmentation, including detecting pauses that fall
  inside a single 5 s chunk. That needs segment timing and is a later spec.
  This spec deliberately prefers a missed break to a spurious one.
- A spoken "new paragraph" command.
- Any change to quick-dictation targeting, `FocusContextMonitor`,
  `SmartSpacing`, or `leadingSilenceSeconds`.

## Decisions

### 1. Drain safely (R-02)

- **Single-flight stop.** `stopRecording()` stores its work in
  `private var stopTask: Task<Void, Never>?`. A second call while one runs
  awaits the same task and returns, and does nothing else.
- **Flush tasks.** Each periodic flush runs in its own task (`flushTask`),
  created by the loop and awaited by it, so cancelling `loopTask` (which wakes
  its sleep) never cancels a transcription in progress.
- **Stop order.**
  1. Cancel and nil `loopTask`.
  2. `await flushTask?.value`.
  3. Run the forced final flush. This calls `stopCapture()` and does **not**
     restart capture. The audio is merged with any `carryPCM` and transcribed
     regardless of `minChunkBytes` (the existing `force` rule).
  4. `session.stop()`.

  Step 3's `stopCapture()` is the final cutoff, so nothing captured after the
  user pressed ⌘. is kept.
- **Session binding.** `startRecording` records the new session's id.
  `appendChunk` takes that id and ignores a chunk whose id does not match
  `currentSession?.id`, so late work can never land in another session.
- **⌘↩ during recording.** `CockpitCoordinator` gains an injected
  `drainRecording: (@MainActor () async -> Void)?`, which `AppCoordinator`
  wires to `cockpitCapture.stopRecording`. `insertIntoTarget` awaits it when
  the session is `.recording`, then requires `.reviewing` before inserting.
  The Notion branch follows the same rule.
- **Terminal interruption.** `endSessionAfterInterruption` stores the audio
  `stopCapture()` returns, plus any `carryPCM`, in `RejectedAudioStore`
  (reason `interrupted_tail`) with a receipt, when it is non-silent. It then
  appends the marker (see Decision 2) and stops. Silent audio is dropped.
- **Per-recording reset.** `startRecording` resets `carryPCM`,
  `consecutiveTranscriptionFailures`, the pause accounting, and the speech
  reference (Decision 2).

### 2. Pauses at chunk boundaries; correct joins (R-03)

- **Quiet helpers.** New pure helpers on `CapturedAudio` use a fixed grid of
  20 ms frames from the start of the PCM; the last partial frame counts by its
  actual duration:
  - `func frameRMSValues() -> [Double]`
  - `func leadingQuietSeconds(threshold: Double) -> Double`
  - `func trailingQuietSeconds(threshold: Double) -> Double`

  The quiet helpers return the summed duration of consecutive frames below
  `threshold` from that end, or `durationSeconds` when every frame is quiet,
  or 0 for empty PCM.
- **Adaptive quiet threshold.** The coordinator keeps a per-recording speech
  reference, `speechReference`, which starts at `CapturedAudio.speechFloor`.
  After each chunk whose 95th-percentile frame RMS is at least
  `silenceFloor * 3`, it updates to `max(speechReference * 0.8, p95)`. The
  threshold is `max(CapturedAudio.silenceFloor * 1.5, 0.3 * speechReference)`.
  - A weak speaker (speech near 0.01) gets a threshold near 0.003, so their
    speech is not "quiet".
  - A normal speaker gets roughly 0.006 to 0.03, so room noise near 0.005 is
    quiet for them.
  - The constants live in one place: `CockpitPauseDetector`, a small pure type
    with `mutating func observe(_ audio: CapturedAudio)` and
    `var quietThreshold: Double`.
- **Pause accounting.** `pendingPause` starts at 0 for each recording. For
  each merged chunk:
  - **Appended as text:** `pauseBefore = pendingPause +
    leadingQuietSeconds`, then `pendingPause = trailingQuietSeconds`.
  - **Every frame quiet** (dropped, or empty text): `pendingPause +=
    durationSeconds`.
  - **Contains non-quiet frames but produced no text** (gate rejection,
    transcription error): `pendingPause = trailingQuietSeconds`. Speech
    happened, so the quiet run restarts after it, and unrecognized speech
    never becomes a fictitious pause.
  - **Carried as sub-minimum:** no change until it is merged.
  - The ~150 ms restart gap is not counted, so a measured 2.0 s means a real
    pause of at least about 2.0 s.
- **Paragraph threshold.** `LongFormSessionService.paragraphBreakPause = 2.0`
  seconds. `lastChunkAt` and `paragraphBreakSilence` are removed.
- **`appendChunk(_ chunk: String, pauseBefore: TimeInterval, sessionID: UUID)`**
  (ignored when `sessionID` does not match):
  - Empty transcript: the chunk becomes the transcript.
  - `pauseBefore >= paragraphBreakPause`: trim trailing whitespace from the
    transcript, append `\n\n`, then the chunk.
  - Otherwise: `transcript = ChunkJoiner.join(transcript, chunk)`.
- **`ChunkJoiner.join(_ previous: String, _ next: String) -> String`** is a
  new pure function:
  - **No separator** when `previous` is empty or ends in whitespace; when it
    ends in an opening character (`(` `[` `{` `“` `‘` `«` `¿` `¡`); or when
    `next` starts with a closing or attaching character (`.` `,` `;` `:` `!`
    `?` `)` `]` `}` `”` `’` `»` `…` `%`).
  - **Otherwise exactly one space.** This includes `next` starting with `“`,
    a straight `"`, a digit, or a letter.
  - **Known limitation:** a rare mid-word cut gets a space.
- **Interruption marker.** `LongFormSessionService.appendInterruptionMarker(_
  reason: String, sessionID: UUID)` trims trailing whitespace and newlines from
  the transcript. If the transcript is non-empty it appends `\n\n`, then
  `[recording interrupted — <reason>]`. The coordinator uses it instead of
  `appendChunk("\n\n[...]")`.

### 3. Target the last app that is not VoxFlow, verified (R-04)

- **Tracking.** A new `ExternalAppTracker` (`@MainActor`) records the most
  recent activated application that is not VoxFlow as `ExternalAppIdentity`
  (`pid`, `bundleID`, `name`).
  - Pure core: `mutating func record(pid: Int32, bundleID: String?, name:
    String?, ownPID: Int32)`, which ignores `pid <= 0`, `ownPID`, and a nil
    bundle ID.
  - Production feeds it from
    `NSWorkspace.shared.notificationCenter`'s `didActivateApplicationNotification`.
  - It is seeded once at app launch from `NSWorkspace.shared.frontmostApplication`,
    unless that is VoxFlow, and again when the cockpit opens, before the
    window activates.
  - Reading the frontmost app at launch or open is not an insert-time read, so
    the CLAUDE.md rule holds.
  - `AppState` gains `@Published var lastExternalApp: ExternalAppIdentity?`.
- **Freeze at ⌘R.** ⌘R calls `ExternalAppTracker.currentVerified()`. This
  returns the identity only if `NSRunningApplication(processIdentifier:)`
  exists, is not terminated, and has the same `bundleIdentifier`; otherwise
  nil. A non-nil identity becomes the session's `targetApp` snapshot
  (`FocusTargetSnapshot` with the pid, bundleID, and name, no text-input
  flags); nil means "no target", exactly as today.
- **Insert-time verification.** A pure helper
  `nonisolated static func resolveTarget(pid: Int32?, expectedBundleID: String?,
  lookup: (Int32) -> (bundleID: String?, terminated: Bool)?) -> Int32?`
  is used by both `CockpitCoordinator.insertIntoTarget` and the chain
  executor's `frozenTarget` closure. A bundle-ID mismatch or a terminated app
  resolves to no target, so insert fails the existing safe way
  (TARGET_UNAVAILABLE, clipboard fallback).
- **Side panel.** The side panel shows `lastExternalApp.name` only when there
  is no current session. A session with no frozen target keeps today's
  "focused app" text.
- `FocusContextMonitor` and `state.focusTarget` are untouched.

### 4. Chains seed from the transcript (R-05)

- `ChainExecutor.run` starts `var workingText = currentTranscript() ?? ""`.
  `.capture` still re-seeds, and still fails with `.noTranscript` when the
  transcript is empty.
- An `.action` with empty `workingText` stops with `.noTranscript` and sends
  no request.
- **Result-contract change, intentional:**
  - Insert-only chains insert the current transcript.
  - App-step-only chains, and chains that fail before any `.capture`, report
    the current transcript as `finalText`, not `""`.
  - `test_insert_only_chain_with_empty_text_fails_without_clipboard` is
    rewritten to expect the transcript. Its empty-transcript variant keeps the
    `.insertFailed`, no-clipboard expectation.
- The app-step tests in `ChainExecutorTests.swift` (from about line 379) are
  methods on `CallCounter`, not the `XCTestCase`, so they never run. Move them
  onto the test case and make them pass.
- Update `ChainStore.seedChains`' comment.

## Error handling

- A transcription error in the awaited flush follows the existing path:
  audio retained, receipt written, failure counted. A third consecutive failure
  ends the session through `endSessionAfterInterruption`, which now retains
  the buffered tail too. A stop already in progress then sees `.reviewing` and
  returns.
- No new user-facing strings beyond the unchanged interruption marker
  wording.

## Testing (fakes only; deterministic: continuations, not sleeps)

- **Capture fake.** Upgrade it to model consumption: a queue of PCM buffers
  served one per `stopCapture()`, a running flag, and a count of restarts. It
  fails the test on a stop while not running.
- **Transcriber fake.** Each call suspends on a continuation the test releases.
- **Drain:**
  - Stop during an in-flight transcription: the held chunk, then the tail, are
    both in the transcript, and the state is `.reviewing`.
  - Double stop: both calls return, the tail is appended exactly once, and
    there is no restart after the final cut.
  - Stop during flush deferral.
  - Stop after a restart failure.
  - A third-failure interruption with a buffered tail: the tail is retained in
    the rejected-audio fake.
  - ⌘↩ during recording drains first and then inserts the complete transcript.
  - A late chunk from an old session id is ignored.
  - A new recording starts with empty carry and failure counters.
- **`CockpitPauseDetector` and the quiet helpers**, with synthetic PCM:
  - All quiet.
  - 1.0 s quiet, then speech, then 0.5 s quiet: leading ≈ 1.0, trailing ≈ 0.5
    (±1 frame).
  - Weak speech at 0.01 after observing weak speech is not quiet.
  - Room noise at 0.005 after observing normal speech is quiet.
  - Empty PCM.
- **Pause accounting:**
  - Continuous speech across three flushes gives one paragraph.
  - A ≥ 2 s quiet span across a boundary gives one break.
  - An all-quiet window between two speech chunks gives a break.
  - A gate-rejected speech chunk does not create a break.
  - A carried sub-minimum merge counts once.
- **`ChunkJoiner`:**
  - `"world."+"Second"` → `world. Second`
  - `"He said"+"“hello”"` → `He said “hello”`
  - `"(note"+")"` → `(note)`
  - `"Hello"+","` → `Hello,`
  - `"x\n\n"+"y"` → `x\n\ny`
  - `"rate"+"%"` → `rate%`
  - `"3"+"14"` → `3 14` (documented)
- **`appendChunk` and `appendInterruptionMarker`:**
  - 1.9 joins, 2.0 breaks.
  - No more than one blank line ever.
  - A marker after an existing `\n\n` yields exactly one blank line.
  - A mismatched session id is ignored.
  - The two wall-clock tests are replaced.
- **Targeting:**
  - `ExternalAppTracker.record` ignores own PID, non-positive PIDs, and a nil
    bundle ID, and keeps the latest external app.
  - `resolveTarget` handles a matching bundle, a mismatched bundle (a reused
    PID gives nil), a terminated app, and a nil PID.
  - ⌘R freezes the verified identity.
- **`ChainExecutor`:**
  - Seeded "Memo" and "Action items" act on the transcript.
  - Empty transcript before an action gives `.noTranscript` with no backend
    call.
  - The rewritten insert-only test.
  - The relocated app-step tests run and pass.

Manual acceptance (installed app):
- Open the cockpit from Slack with ⌥⌘V. Record about 20 s of continuous
  speech, then a deliberate 3 s pause, then speech. Expect no break in the
  continuous part, and a break at the pause when it spans a chunk boundary.
- Press ⌘. twice mid-sentence: the final words are present once.
- ⌘↩ during recording inserts the complete transcript into Slack.
- Run "Memo".

## Acceptance criteria

- All four goals verified by the tests above. Full Swift and Python suites are
  green.
- Manual acceptance passes on the installed app.
- `ChainStore.seedChains`' comment and CLAUDE.md's Cockpit section are updated.
  The section currently documents the old rule ("`appendChunk(_:)` inserts a
  `\n\n` paragraph break if ≥4 s of silence elapsed since the last chunk"); it
  must describe the measured-boundary-pause rule, `ChunkJoiner`, and the
  verified last-external-app target.
