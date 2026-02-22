# VoxFlow Dictation Pipeline Fix — Design Document

**Date:** 2026-02-21
**Status:** Draft
**Scope:** Fix two end-to-end dictation bugs: Notion text insertion failure + incorrect transcription in other apps

---

## Problem Statement

Both sounds (Tink start + Basso stop) play correctly, confirming the fn key detection and audio capture pipeline work. Two downstream bugs:

1. **Notion (Electron apps):** No text appears. The simulated Cmd+V paste fires but doesn't land in Notion because (a) no target app activation before paste, (b) zero delay between clipboard write and keystroke simulation, (c) no verification that the paste landed.

2. **Other apps:** Incorrect/garbage text. Compound of: (a) 48kHz audio captured at hardware rate, relying on backend torchaudio resampling (lossy chain), (b) `autoInsertLight` default routes through FLAN-T5-Small cleanup which mangles marginal Whisper transcriptions.

## Design — Four Targeted Fixes

### Fix 1: Reliable Text Insertion

**File:** `AccessibilityInsertService.swift`

**Changes to `simulatePaste`:**

1. Before posting Cmd+V, save the focused app's `NSRunningApplication` reference (from `NSWorkspace.shared.frontmostApplication`)
2. Before posting Cmd+V, call `targetApp.activate()` to ensure the target app is frontmost
3. Add a 150ms `usleep` delay between `NSPasteboard.setString` and `CGEvent.post` — gives Electron/browser apps time to register the clipboard change
4. After posting Cmd+V, add a 100ms delay, then restore the user's previous clipboard contents (save before, restore after)

**Changes to `TextInsertionCoordinator`:**

5. Before calling `insertService.insert()`, capture `NSWorkspace.shared.frontmostApplication` and pass it to the insert method so it knows which app to activate

**Rationale:** macOS HID events go to the frontmost app. During the async transcription+cleanup pipeline (which takes 2-10 seconds), focus can shift. Explicitly activating the target app before pasting ensures the Cmd+V lands in the right window.

### Fix 2: Client-Side Audio Resampling to 16kHz

**File:** `AudioCaptureService.swift`

**Changes:**

1. After `engine.inputNode.outputFormat(forBus: 0)` returns the hardware format (typically 48kHz), create an `AVAudioFormat` for the target: 16kHz, mono, Int16
2. Use `AVAudioConverter` to resample each buffer from hardware rate to 16kHz before appending to `pcmBuffer`
3. Set `sampleRate = 16000` (constant) so `CapturedAudio.sampleRate` always reports 16kHz
4. The backend receives 16kHz audio labeled as 16kHz — no resampling needed on the Python side

**Rationale:** Whisper was trained on 16kHz audio. Resampling at capture time using Apple's optimized `AVAudioConverter` (which uses vDSP/Accelerate internally) is higher quality than the torchaudio resampling in the HF pipeline. It also reduces the payload size by 3x (48kHz → 16kHz), cutting transcription latency.

### Fix 3: Default to Raw Insertion (Skip FLAN-T5 Cleanup)

**File:** `SettingsCoordinator.swift`

**Changes:**

1. Change the default `insertBehavior` fallback from `.autoInsertLight` to `.autoInsertRaw`
2. When `insertBehavior` is `.autoInsertRaw`, the raw Whisper transcription is inserted directly — no `/v1/cleanup` call, no FLAN-T5 processing

**Rationale:** FLAN-T5-Small is a small generative model (~250M params) that often degrades marginal Whisper output. For dictation, users expect their words verbatim. The cleanup step is an optional refinement, not a core requirement. Users who want cleanup can switch to `.autoInsertLight` or `.autoInsertPolish` in Settings.

### Fix 4: Diagnostic Logging

**File:** `AppCoordinator.swift`

**Changes:**

Add `log.info(...)` or `log.warning(...)` calls at every silent guard/return in `startCapture()` and `finishCaptureAndTranscribe()`:

- Line 164: `log.warning("startCapture blocked: sessionState=\(state.sessionState)")`
- Line 168: `log.warning("startCapture blocked: mic not authorized")`
- Line 174: `log.warning("startCapture blocked: accessibility not authorized")`
- Line 179: `log.warning("startCapture blocked: backend not ready")`
- Line 184: `log.warning("startCapture blocked: no focused text target")`
- Line 225: `log.warning("finishCapture blocked: sessionState=\(state.sessionState), expected .recording")`
- After transcription: `log.info("Transcription result: '\(rawText.prefix(80))...' (confidence=\(transcription.confidenceEstimate))")`
- After insertion: `log.info("Insert result: method=\(result.method), success=\(result.success), fallback=\(result.fallbackUsed)")`

**Rationale:** Currently 5 of 5 guards in `startCapture()` fail silently with no log output. This makes it impossible to diagnose "nothing happens" from Console.app logs.

## Files Modified

| File | Change |
|---|---|
| `Sources/VoxFlowApp/Services/AccessibilityInsertService.swift` | Activate target app, delay before paste, save/restore clipboard |
| `Sources/VoxFlowApp/Services/AudioCaptureService.swift` | AVAudioConverter resampling to 16kHz |
| `Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift` | Pass target app reference to insert service |
| `Sources/VoxFlowApp/Services/SettingsCoordinator.swift` | Default insertBehavior → .autoInsertRaw |
| `Sources/VoxFlowApp/AppCoordinator.swift` | Add diagnostic logging at all guards |

## Testing Plan

1. **Unit test:** Verify `AudioCaptureService` always reports 16kHz sample rate
2. **Integration test:** Confirm backend receives 16kHz audio and produces clean transcription
3. **Manual test — TextEdit:** fn hold → speak → release → text appears correctly
4. **Manual test — Notion:** fn hold → speak → release → text appears in Notion
5. **Manual test — Notes:** fn hold → speak → release → text appears in Notes
6. **Console.app:** Verify diagnostic logs appear for `local.voxflow.app` subsystem

## Risks

- `AVAudioConverter` resampling adds a small CPU cost per audio frame (~negligible on Apple Silicon)
- The 150ms paste delay slightly increases perceived insertion latency
- Changing default to `.autoInsertRaw` means new users get unpolished text — but it's accurate text, which is the higher priority
