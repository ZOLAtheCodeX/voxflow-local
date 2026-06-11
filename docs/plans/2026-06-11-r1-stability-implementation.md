# R1 stability implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the ghost-"hello" bug class with layered gating and fix the verified stability bugs from the 2026-06-11 audit, returning both suites to green.

**Architecture:** Layered anti-hallucination defense: behavioral parity fixture (one contract, two implementations) -> explicit decode thresholds + noSpeechProb-aware coverage confidence -> a single `TranscriptGate` applied at every transcript ingress. Bug fixes are surgical, each with a regression test. Verified-false-positive findings (S3, possibly S5) get a pinning test or a documented correction instead of a code change.

**Tech stack:** Swift 6.2 strict concurrency / XCTest; Python 3.11 / FastAPI / pytest. Branch `r1-stability` off local master `e9029a1`.

**Verification commands:**
- Swift: `swift test 2>&1 | tail -5`
- Python: `./.venv/bin/python -m pytest backend/tests -q 2>&1 | tail -5`

---

### Task 1 (R1.1): Behavioral parity fixture

**Files:**
- Create: `Tests/Fixtures/hallucination_parity.json`
- Modify: `backend/app/nlp/hallucination.py` (add greeting-pair phrases, short-only words, bracket-cue rule, "see you next time" family)
- Modify: `Sources/VoxFlowApp/Services/HallucinationFilter.swift` (no behavior change expected; only if a fixture case exposes drift)
- Modify: `backend/tests/test_utils.py` (replace `TestHallucinationParity` regex test with fixture-driven test)
- Modify: `Tests/VoxFlowAppTests/HallucinationFilterTests.swift` (add fixture-driven test)

Fixture schema: `[{"text": "...", "short_audio": true|false, "expected": true|false, "note": "..."}]`. Each case must hold in BOTH implementations. Cases pin: greetings (hello/hi/hey, punctuated, both durations -> true), greeting pairs ("hello everyone", "hi guys", "hey there" -> true both durations), short-only words (yeah/yes/okay/ok/you/bye/thanks: short -> true, long -> false), YouTube outros (true), music notes/ellipsis (true), 3+ identical repeats (short -> true, long -> false), bracket cues "[typing sounds]" (true), and the protective FALSE cases: "Hello world", "Hello, how are you?", lone real words ("Approved", "Cancel", "Seven"), "I'm watching the kids", "change the channel", "subscribe me to the newsletter", "no no no" on long audio, "send it".

Python gains for parity: greeting-pair phrases (3 greetings x everyone/everybody/guys/there), `yeah/yes/okay/ok` in SHORT_ONLY, "See you next time." family in ALWAYS, and a whole-string-enclosed bracket/paren/star + cue-word rule mirroring Swift.

- [ ] Write fixture JSON
- [ ] Python: fixture-driven test replaces regex test; run -> expect failures on the parity-gap cases
- [ ] Python: extend `hallucination.py` until green
- [ ] Swift: fixture-driven XCTest (resolve path via `#filePath` -> repo root); run -> expect green or fix drift
- [ ] Both suites green; commit

### Task 2 (R1.3): Coverage-based confidence on the WhisperKit path

**Files:**
- Create: `Sources/VoxFlowApp/Services/TranscriptionConfidence.swift`
- Modify: `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift:60-65`
- Test: `Tests/VoxFlowAppTests/TranscriptionConfidenceTests.swift`

```swift
import Foundation

/// Coverage-based confidence for WhisperKit results — parity with the backend's
/// `WhisperEngine._estimate_confidence` (whisper.py), plus a noSpeechProb signal
/// the backend pipeline does not expose.
enum TranscriptionConfidence {
    struct SegmentSignal {
        let startSeconds: Double
        let endSeconds: Double
        let noSpeechProb: Double
    }

    static func estimate(segments: [SegmentSignal], text: String, audioDurationSeconds: Double) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count

        var spoken = 0.0
        for seg in segments { spoken += max(0.0, seg.endSeconds - seg.startSeconds) }

        let coverage: Double
        if spoken > 0, audioDurationSeconds > 0 {
            coverage = min(1.0, spoken / audioDurationSeconds)
        } else {
            let expectedWords = audioDurationSeconds * 2.5
            coverage = min(1.0, Double(wordCount) / max(expectedWords, 1.0))
        }

        var confidence = min(0.95, max(0.05, coverage))
        if wordCount <= 2, audioDurationSeconds > 2.0, coverage < 0.3 {
            confidence = min(confidence, 0.1)
        }
        let meanNoSpeech = segments.isEmpty ? 0.0 : segments.map(\.noSpeechProb).reduce(0, +) / Double(segments.count)
        if meanNoSpeech > 0.5 {
            confidence = min(confidence, 0.1)
        }
        return (confidence * 1000).rounded() / 1000
    }
}
```

`WhisperKitSTTService` maps ALL segments of ALL results into `SegmentSignal` (segment `start`/`end` are Float seconds; `noSpeechProb` Float) and calls `estimate`.

- [ ] Failing tests: full-coverage speech ~0.9x; lone word over 5 s noise <= 0.1; high mean noSpeechProb caps at 0.1; empty text -> 0; no-timestamp fallback path
- [ ] Implement; wire into WhisperKitSTTService; suite green; commit

### Task 3 (R1.2): Explicit decode thresholds + silence/noise regression clips

**Files:**
- Modify: `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift:50-54` (make `noSpeechThreshold: 0.6`, `logProbThreshold: -1.0`, `compressionRatioThreshold: 2.4`, `temperatureFallbackCount: 5` explicit — pins against upstream default drift; values unchanged from WhisperKit defaults by design)
- Modify: `backend/tests/generate_golden_clips.py` + `backend/tests/regression_manifest.json` (add `silence_3s` and `ambient_noise_4s` clips, expected transcript empty)
- Test: regression suite run (model-dependent, local only)

The HF pipeline path keeps its current kwargs (short-form `chunk_length_s=0` does not support `no_speech_threshold` in transformers 4.56; the confidence + filter + gate layers are the defense there — documented in code comment).

- [ ] Explicit DecodingOptions; build green
- [ ] Generate clips (numpy: zeros; 0.008-RMS uniform noise), manifest entries
- [ ] Run `backend/tests/run_regression_suite.py` locally if models present; record results
- [ ] Commit

### Task 4 (R1.4): TranscriptGate at every ingress

**Files:**
- Create: `Sources/VoxFlowApp/Services/TranscriptGate.swift`
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:662-685` (replace inline checks with gate call)
- Modify: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift` (gate the chunk; `minChunkBytes` 8_000 -> 9_600 = 0.3 s)
- Test: `Tests/VoxFlowAppTests/TranscriptGateTests.swift`; update `CockpitCaptureCoordinatorTests`

```swift
enum TranscriptGate {
    static let minAudioSeconds = 0.3

    enum Verdict: Equatable {
        case accepted
        case rejected(reason: String)
    }

    static func evaluate(text: String, confidence: Double, audioDurationSeconds: Double) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .rejected(reason: "empty") }
        if trimmed.hasPrefix("[transcription") { return .rejected(reason: "placeholder") }
        let shortAudio = audioDurationSeconds < 3.0
        if HallucinationFilter.isLikelyHallucination(trimmed, shortAudio: shortAudio) {
            return .rejected(reason: "hallucination_filter")
        }
        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let isSuspect = (wordCount == 1 && confidence < 0.15)
            || (shortAudio && wordCount <= 2 && confidence < 0.08)
            || (wordCount <= 3 && audioDurationSeconds > 4.0 && confidence <= 0.1)
        if isSuspect { return .rejected(reason: "low_confidence") }
        return .accepted
    }
}
```

The third `isSuspect` clause is the new layer: a <=3-word result from >4 s of audio whose coverage confidence collapsed to <=0.1 (the R1.3 caps) is exactly the long-noise ghost signature.

- [ ] Failing TranscriptGateTests (incl. ghost signature case: "hello world", conf 0.1, 5 s -> rejected)
- [ ] Implement; rewire AppCoordinator + Cockpit; suite green; commit

### Task 5 (R1.5): Backend OpenAI STT parity

**Files:**
- Modify: `backend/app/api/endpoints.py:159-175` (drop the `stt_backend != "openai"` exemption)
- Modify: `backend/app/engines/whisper.py` OpenAIAudioClient (replace hardcoded 0.88 with duration-heuristic confidence: `coverage = word_count / max(duration * 2.5, 1)`, clamp 0.05-0.95, lone-word cap as in `_estimate_confidence`)
- Test: `backend/tests/test_endpoints.py` (filter applies on openai backend), `backend/tests/test_whisper_engine.py` (confidence heuristic)

- [ ] Failing tests; implement; green; commit

### Task 6 (R1.6): Cancel during `.transcribing`

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (store pipeline `Task` handle; `.transcribing` branch in `cancelActiveCapture` cancels it, sets idle, zeroes duration)
- Test: `Tests/VoxFlowAppTests/AppCoordinatorSmokeTests.swift`

- [ ] Locate Task creation in the finish path; store `transcriptionTask`; cancel + idle in `.transcribing` branch; CancellationError exits quietly (no error state)
- [ ] Test: cancel while transcribing -> `.idle`; green; commit

### Task 7 (R1.7): Audio device change handling

**Files:**
- Modify: `Sources/VoxFlowApp/Services/AudioCaptureService.swift` (observe `.AVAudioEngineConfigurationChange` for `engine`; if capturing: remove tap, stop engine, flag `deviceChangedDuringCapture`; `stopCapture` then throws new `AudioCaptureError.deviceChanged`; `startCapture` clears flag)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (catch `.deviceChanged` -> idle + status "Audio device changed — try again")
- Test: `Tests/VoxFlowAppTests/AudioCaptureServiceTests.swift` (post the notification, assert flag/throw)

- [ ] Failing test; implement; green; commit

### Task 8 (R1.8): FnHoldHotkeyService thread safety

**Files:**
- Modify: `Sources/VoxFlowApp/Services/FnHoldHotkeyService.swift` (`@MainActor` class; monitor callbacks dispatch to main when off-main)
- Test: existing `FnHoldHotkeyServiceTests` keep passing (they call `handleFlagsChanged` directly on main)

- [ ] Annotate; route global-monitor callback through `DispatchQueue.main.async`; build + tests green; commit

### Task 9 (R1.9): Verified small fixes + false-positive corrections

**Files / sub-items:**
- S3 endpoints semaphore: NO code change. Add `backend/tests/test_endpoints.py::test_ml_semaphore_check_acquire_is_atomic` pinning that check+fast-path-acquire cannot oversubscribe (asyncio single-thread step). Correct `docs/audits/2026-06-11-full-codebase-review.md` S3 entry to "false positive (verified)".
- S4 clipboard: `AccessibilityInsertService.simulatePaste` snapshots `pasteboard.changeCount` after writing; restores ONLY if unchanged (user did not copy during the window).
- S5 settings restarts: read `SettingsView.swift:115-135, 245-270`; if apply is button-driven, mark S5 false positive in the audit doc and skip; else debounce.
- S7 re-insert target: add `targetBundleID: String?`/`targetProcessIdentifier: Int32?` (default nil) to `TranscriptCandidate`; populate in `DictationWorkflowCoordinator`; `insertRecentDictation` resolves `NSRunningApplication(processIdentifier:)` and passes it.
- S9 recordingDuration: zero it at the three insert-completion points in `DictationWorkflowCoordinator`.
- S12 cockpit restart failure: best-effort `_ = try? capture.stopCapture()` before `session.stop()` in the failure branch + status surfacing via session.
- S11 dead `_LAST_CLEANUP_TIME` in `context.py`: delete the dead global, comment in `server.py`.

- [ ] Each sub-item: failing test where testable -> fix -> green; audit doc corrections; commit

### Task 10 (R1.10): API keys out of @Published AppState

**Files:**
- Modify: `Sources/VoxFlowApp/State/AppState.swift:39,41` (delete both properties)
- Modify: `Sources/VoxFlowApp/Services/SettingsCoordinator.swift` (stop loading into state at :102,104; `backendLaunchConfiguration` reads `KeychainService.load` directly; update mutators)
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift:729-731` (drafts load from `KeychainService.load`); fix any other `state.privateAPIKey`/`state.openAIAPIKey` readers (grep)
- Test: `SettingsCoordinatorTests` round-trip via Keychain

- [ ] Grep all readers; migrate; failing/updated tests; green; commit

### Task 11: Exit gate

- [ ] `swift test` green (full count reported)
- [ ] `pytest backend/tests` green
- [ ] Regression suite run (if models present locally)
- [ ] Merge `r1-stability` -> master after verifying master has not moved (concurrent-session guard)
- [ ] Report manual "haunted room" protocol to user (10 ambient-room hotkey taps, 10 cockpit idle minutes, zero ghosts) — user gate
