# Cockpit capture correctness — design spec

Source: the 2026-10-26 multi-model review (triage R-02 to R-05, each verified
against the code by an independent pass). User decisions: fix within the
current stop/restart chunking (continuous capture is a later spec);
paragraph breaks at real pauses only; the cockpit targets the most recent app
that is not VoxFlow, frozen at ⌘R.

## Measured facts driving this work

- **Stop loses speech (R-02).** `CockpitCaptureCoordinator.stopRecording`
  cancels `loopTask`, then calls `flushNow(force: true)`, which returns at
  once on `guard !isFlushing` when a periodic flush is mid-transcription. Then
  `capture.stopCapture()` discards the tail PCM and `session.stop()` moves to
  `.reviewing`, so the late chunk is rejected by `appendChunk`'s
  `guard case .recording`. Separately, the periodic flush runs inside
  `loopTask`, so `loopTask.cancel()` cancels its in-flight
  `transcriber.transcribe`, which can throw and turn that chunk into a
  retained rejected clip instead of text.
- **Paragraph break every 5 s; glued final chunk (R-03).**
  `LongFormSessionService.appendChunk` inserts `\n\n` when wall-clock time since
  the previous append is at least `paragraphBreakSilence` (4.0 s). Appends
  are 5 s apart plus flush deferral (0 to 2 s) plus transcription latency, so
  every chunk after the first in continuous speech starts a paragraph,
  usually mid-sentence. Under 4 s it concatenates with no separator, and chunks
  are trimmed, so the forced stop chunk is often glued on ("world.Second").
- **Cockpit targets itself (R-04).** `CockpitWindowView` ⌘R passes
  `state.focusTarget`. `FocusContextMonitor` keeps polling (it freezes only
  during quick capture), and the cockpit is an activating window, so at ⌘R the
  focused app is VoxFlow or `.unavailable`. ⌘↩ then fails with
  TARGET_UNAVAILABLE or inserts into the cockpit. ⌘R is the only
  `startRecording` caller.
- **Shipped chains always fail (R-05).** `ChainStore.seedChains` ("Memo",
  "Action items") have no `.capture` step "because the executor seeds from the
  current transcript", but `ChainExecutor.run` starts `workingText = ""`, so
  step 1 sends an empty transcript and `/v1/smart_action` answers 422.
- Existing silence measures: `CapturedAudio.silenceFloor` (0.003, dead-air)
  and `speechFloor` (0.02). The quiet-boundary flush treats a tail as quiet
  when its RMS is below `speechFloor * 0.75`
  (`CockpitCaptureCoordinator.shouldDeferFlush`). `CapturedAudio.leadingSilenceSeconds`
  is a per-sample test at `silenceFloor` used for empty-capture forensics. Room
  noise defeats it, so it is not suitable for pause detection.

## Goals

1. Stopping a cockpit recording never loses speech that was captured.
2. Paragraph breaks follow measured pauses in the audio, not wall-clock timing;
   chunks otherwise join with correct spacing.
3. ⌘↩ inserts into the most recent app that is not VoxFlow, as of ⌘R.
4. The shipped chains run their action on the current transcript.

## Non-goals

- Continuous capture or VAD-based segmentation (removing the ~150 ms restart
  gap). A separate later spec.
- A spoken "new paragraph" command in the cockpit.
- Any change to quick-dictation targeting or to `FocusContextMonitor` itself.
- Changing `leadingSilenceSeconds` or the empty-capture forensics.

## Decisions

### 1. Stop waits for the in-flight flush (R-02)

- Each periodic flush runs in its own unstructured task, stored as
  `private var flushTask: Task<Void, Never>?`. The loop creates it and awaits
  `flushTask?.value`, so cancelling `loopTask` (which wakes the loop's sleep)
  never cancels a flush that is already transcribing.
- `stopRecording()` order: cancel `loopTask` and nil it; `await flushTask?.value`
  (the in-flight periodic flush completes, including its append); then
  `await flushNow(force: true)` (the tail); then `capture.stopCapture()`; then
  `session.stop()`. The `isFlushing` single-flight guard stays.
- `endSessionAfterInterruption` is unchanged in behavior (it already stops
  capture and moves to review from inside a flush).

### 2. Paragraphs at measured pauses; correct spacing (R-03)

- New pure helpers on `CapturedAudio`, in 20 ms frames:
  `func leadingQuietSeconds(threshold: Double) -> Double` and
  `func trailingQuietSeconds(threshold: Double) -> Double`. A frame is quiet
  when its RMS is below `threshold`. Each returns the summed duration of
  consecutive quiet frames from that end, or `durationSeconds` if every frame
  is quiet. A trailing partial frame counts by its actual duration.
- One shared threshold: `CockpitCaptureCoordinator.quietRMSThreshold =
  CapturedAudio.speechFloor * 0.75`. `shouldDeferFlush` uses it too, so "quiet"
  means the same thing for cutting chunks and for detecting pauses.
- The coordinator keeps `private var pendingPause: TimeInterval = 0` (reset to
  0 at `startRecording`). On each merged chunk:
  - Appended as text: `pauseBefore = pendingPause + merged.leadingQuietSeconds(...)`,
    then `pendingPause = merged.trailingQuietSeconds(...)`.
  - Dropped as silent, rejected by `TranscriptGate` (any reason, including
    `.empty`), or failed transcription: `pendingPause += merged.durationSeconds`.
    No text reached the transcript, so that time counts as gap.
  - Carried forward as sub-minimum (`carryPCM`): no change to `pendingPause`.
    It is measured when merged.
- `LongFormSessionService.appendChunk(_ chunk: String, pauseBefore: TimeInterval = 0)`
  replaces the wall-clock rule (`lastChunkAt` and `paragraphBreakSilence` are removed):
  - Empty transcript: the chunk becomes the transcript.
  - `pauseBefore >= 2.0` (`paragraphBreakPause`) and the transcript does not
    already end in `\n\n`: append `\n\n` then the chunk.
  - Otherwise: append `SmartSpacing.adjusted(chunk, precedingCharacter: transcript.last)`.
- The interruption marker keeps its own leading `\n\n` and is appended with
  `pauseBefore: 0`, so it never doubles the break.

### 3. Cockpit targets the last app that is not VoxFlow (R-04)

- `AppState` gains `@Published var lastExternalFocusTarget: FocusTargetSnapshot = .unavailable`.
- Pure decider on `AppCoordinator`:
  `nonisolated static func isExternalFocusTarget(_ snapshot: FocusTargetSnapshot, ownPID: Int32) -> Bool`,
  true only when `snapshot.processIdentifier` is non-nil, greater than 0, and
  not `ownPID`.
- `startFocusMonitoring`'s update closure still sets `state.focusTarget`
  exactly as today. When the decider says external, it also sets
  `state.lastExternalFocusTarget`. Unavailable snapshots and VoxFlow's own
  windows never overwrite it.
- `CockpitWindowView` ⌘R passes `state.lastExternalFocusTarget`, or `nil`
  when its `processIdentifier` is nil. `CockpitSidePanelView`'s Target
  section, before a session exists, shows `lastExternalFocusTarget.appName`
  instead of the static "focused app".
- Insert (⌘↩) is unchanged: it already uses the session's frozen
  `targetApp.processIdentifier`.

### 4. Chains seed from the transcript (R-05)

- `ChainExecutor.run` starts `var workingText = currentTranscript() ?? ""`.
  `.capture` still re-seeds, and still fails with `.noTranscript` when the
  transcript is empty.
- An `.action` step with empty `workingText` stops the chain with the existing
  `.noTranscript` failure (no request is sent).
- Intentional behavior change: an insert-only chain now inserts the current
  transcript. `test_insert_only_chain_with_empty_text_fails_without_clipboard`
  pinned the old "inserts empty text" behavior. It is rewritten to expect the
  transcript, and its empty-transcript variant keeps the `.insertFailed`,
  no-clipboard expectation.

## Error handling

- A transcription error during the awaited in-flight flush follows the
  existing path: audio retained, receipt written, failure counted. Stop then
  proceeds to the tail flush.
- If the forced tail flush hits a capture error, the existing
  `endSessionAfterInterruption` path applies. The marker lands with
  `pauseBefore: 0`.
- No new user-facing strings.

## Testing (fakes only; no real audio, AX, or processes)

- `CapturedAudio` helpers, with synthetic PCM:
  - All quiet: both helpers equal `durationSeconds`.
  - 1.0 s quiet, then speech, then 0.5 s quiet: leading ≈ 1.0, trailing ≈ 0.5 (±1 frame).
  - Noise at RMS 0.005 counts as quiet, unlike `leadingSilenceSeconds`.
  - Empty PCM: 0.
- `LongFormSessionService.appendChunk`:
  - First chunk is verbatim.
  - `pauseBefore` 1.9 joins with a space ("world." + "Second" → "world. Second").
  - 2.0 starts a paragraph.
  - No double break after an existing `\n\n`.
  - Punctuation-leading chunks join without a space (SmartSpacing rules).
  - The interruption marker with `pauseBefore: 0` yields exactly one `\n\n`.
  - The two wall-clock tests (`test_silence_longer_than_4s…`,
    `test_silence_under_4s…`) are replaced by these.
- `CockpitCaptureCoordinator`, with fake capture and transcriber:
  - Stop during an in-flight transcription: the held chunk and the tail both
    end up in the transcript, in order, and the state is `.reviewing`.
  - Continuous speech across three flushes (no quiet at the boundaries) gives
    one paragraph with spaces.
  - A fully silent window between two speech chunks (≥ 2 s) gives a paragraph break.
  - A gate-rejected chunk's duration counts toward the next pause.
  - Cancelling the loop does not cancel an in-flight transcription.
- `AppCoordinator.isExternalFocusTarget`: own PID false, nil PID false, PID 0
  false, another PID true.
- `ChainExecutor`:
  - Seeded "Memo" and "Action items" apply their action to the transcript.
  - Empty transcript before an action gives `.noTranscript` and no backend call.
  - The insert-only chain is rewritten as above.

Manual acceptance (installed app):
- Open the cockpit from Slack. Record about 20 s of continuous speech with one
  deliberate 3 s pause. Expect one paragraph break, at the pause.
- Stop mid-sentence: the final words are present.
- ⌘↩ inserts into Slack.
- Run "Memo" on the transcript.

## Acceptance criteria

- All four goals verified by the tests above; full Swift and Python suites
  green.
- Manual acceptance passes on the installed app.
- `ChainStore.seedChains`' comment matches the new behavior.
- CLAUDE.md's Cockpit section, which documents the old rule
  ("`appendChunk(_:)` inserts a `\n\n` paragraph break if ≥4 s of silence
  elapsed since the last chunk"), describes the measured-pause rule and the
  last-external-app target instead.
