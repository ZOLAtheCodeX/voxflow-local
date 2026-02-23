# WhisperKit Native STT Integration — Design Document

> **Date:** 2026-02-22
> **Status:** Approved
> **Approach:** A — WhisperKit as new `STTBackend` case

---

## Goal

Replace the Python-backend HTTP roundtrip for speech-to-text with native in-process WhisperKit inference on Apple Neural Engine. Expected latency improvement: 3-5x (from ~3-5s to ~0.5-1s for 30s audio).

## Scope — Phase 1 Only

**In scope:**
- Add WhisperKit SPM dependency
- New `WhisperKitSTTService` class (model load, transcribe, unload)
- New `STTBackend.whisperKit` enum case
- Branch in `AppCoordinator.finishCaptureAndTranscribe()` to bypass HTTP for WhisperKit
- Port hallucination filter from Python to Swift (same patterns)
- Model download script (`scripts/download_whisperkit_model.sh`)
- Updated readiness logic (WhisperKit doesn't need backend for STT)
- Settings UI updates (picker, note text)
- Tests for hallucination filter + WhisperKitSTTService model resolution

**Out of scope:**
- Streaming partial results (future — uses WhisperKit's `segmentCallback`)
- Eliminating Python backend (still needed for cleanup, translation, privacy, meeting)
- CoreML model conversion (using pre-compiled models from argmaxinc/whisperkit-coreml)
- Moonshine v2 or MLX Audio evaluation

## Architecture

### Current Flow (Python backend STT)
```
AudioCaptureService → CapturedAudio (PCM16LE Data)
    → base64 encode → HTTP POST /v1/transcribe → Python decode
    → HuggingFace pipeline (PyTorch/MPS) → JSON response
    → AppCoordinator receives TranscribeResponse
```

### New Flow (WhisperKit STT)
```
AudioCaptureService → CapturedAudio (PCM16LE Data)
    → convert to [Float] (same normalization AudioCapture already does)
    → WhisperKitSTTService.transcribe() (in-process, CoreML/ANE)
    → TranscribeResponse (same type, same downstream path)
```

### Branch Point

`AppCoordinator.finishCaptureAndTranscribe()` at line 286. Currently:

```swift
let transcription = try await BackendAPIClient.transcribe(...)
```

Becomes:

```swift
let transcription: TranscribeResponse
if state.sttBackend == .whisperKit {
    transcription = try await whisperKitService.transcribe(capturedAudio)
} else {
    transcription = try await BackendAPIClient.transcribe(...)
}
```

Everything downstream is unchanged: hallucination check, workflow routing, cleanup, insertion.

## Components

### 1. WhisperKitSTTService

New file: `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift`

```
@MainActor
final class WhisperKitSTTService {
    private var pipe: WhisperKit?
    private(set) var isLoaded = false

    func load(modelFolder: String) async throws
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse
    func unload()
}
```

**Model loading:**
- Reads CoreML model from `models/whisperkit-coreml__openai_whisper-small.en/`
- Config: `WhisperKitConfig(modelFolder:, download: false, prewarm: true, load: true)`
- Compute: `.cpuAndNeuralEngine` for encoder + decoder (ANE default)

**Audio conversion:**
- `CapturedAudio.pcm` is `Data` containing Int16 PCM at 16kHz
- Convert to `[Float]` normalized to [-1.0, 1.0]: `Int16(sample) / 32768.0`
- This is the same normalization the Python backend does (`np.int16 → float32 / 32768.0`)

**Transcription:**
- `pipe.transcribe(audioArray:, decodeOptions: DecodingOptions(language: "en"))`
- Map result to `TranscribeResponse`: text from joined segments, confidence from `avgLogprob`, latency measured via `ContinuousClock`

**Hallucination filter:**
- Applied in `WhisperKitSTTService.transcribe()` before returning
- Same two-tier logic as Python: always-filter set + short-audio-only set
- Ported to Swift as static `Set<String>` properties

### 2. HallucinationFilter

New file: `Sources/VoxFlowApp/Services/HallucinationFilter.swift`

```
enum HallucinationFilter {
    static func isLikelyHallucination(_ text: String, shortAudio: Bool) -> Bool
}
```

Ported directly from `backend/app/server.py` lines 707-768:
- `alwaysFilteredPhrases`: "Thank you for watching", "Subscribe", music notes, "..."
- `shortOnlyPhrases`: "Thank you.", "Thanks.", "Bye.", "you"
- Repeated single-word check: 3+ words, all identical

### 3. STTBackend Enum Update

In `AppModels.swift`, add case:

```swift
enum STTBackend: String, CaseIterable, Identifiable, Codable {
    case voxtral
    case whisper
    case whisperKit
    case openAI
}
```

Display name: `"WhisperKit (Local, Neural Engine)"`

### 4. AppCoordinator Changes

- New property: `private let whisperKitService = WhisperKitSTTService()`
- In `warmup()`: if `sttBackend == .whisperKit`, load WhisperKit model (parallel with backend warmup)
- In `finishCaptureAndTranscribe()`: branch on `state.sttBackend`
- In `startCapture()`: relax `backendReadyForDictation` guard when `sttBackend == .whisperKit` AND workflow is `.dictation` with auto-insert raw (no backend needed at all)

**Readiness logic:**
- When `sttBackend == .whisperKit`: ready = WhisperKit model loaded. Backend readiness still checked separately for cleanup/translation features.
- New property: `state.whisperKitReady: Bool` — set true when model loads
- Guard in `startCapture()` becomes: `backendReadyForDictation || (sttBackend == .whisperKit && whisperKitReady)`

### 5. SettingsCoordinator Changes

- `selectSTTBackend(.whisperKit)` does NOT restart the Python backend (no backend config needed)
- Persist `.whisperKit` in UserDefaults like other backends
- Default for new installs remains `.voxtral` (WhisperKit is opt-in until validated)

### 6. Settings View Changes

- STT picker shows "WhisperKit (Local, Neural Engine)" option
- Note text: "WhisperKit runs Whisper on Apple Neural Engine. Fastest local option. No network access."
- Hide Voxtral-specific controls (safe mode toggle) when WhisperKit is selected

### 7. Model Download Script

New file: `scripts/download_whisperkit_model.sh`

Downloads `openai_whisper-small.en` CoreML model from `argmaxinc/whisperkit-coreml` on HuggingFace to `models/whisperkit-coreml__openai_whisper-small.en/`.

Uses `huggingface-cli download` (already available in the venv) or `curl` fallback.

### 8. Package.swift Update

Add WhisperKit dependency:

```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
],
```

Add `"WhisperKit"` to VoxFlowApp target dependencies.

## Data Flow

```
User holds Fn → AudioCaptureService.startCapture()
User releases Fn → AudioCaptureService.stopCapture() → CapturedAudio

if sttBackend == .whisperKit:
    CapturedAudio.pcm → [Float] conversion
    → WhisperKit.transcribe(audioArray:)
    → HallucinationFilter.isLikelyHallucination()
    → TranscribeResponse
else:
    CapturedAudio.pcm → base64 → HTTP POST → Python backend
    → TranscribeResponse

→ Existing downstream: workflow routing, cleanup, insertion
```

## Error Handling

| Error | Behavior |
|-------|----------|
| WhisperKit model not found in models/ | `state.whisperKitReady = false`, capture blocked with "WhisperKit model not found — run download_whisperkit_model.sh" |
| WhisperKit transcription throws | Same as current: `state.sessionState = .error`, show error message |
| ANE compilation on first run (10-30s) | Happens during `warmup()` — status line shows "Loading WhisperKit model..." |
| Empty transcription result | Same hallucination filter path: discard, show "No speech detected" |

## Testing

| Test | Type | File |
|------|------|------|
| HallucinationFilter always-filtered phrases | Unit | `Tests/VoxFlowAppTests/HallucinationFilterTests.swift` |
| HallucinationFilter short-only phrases | Unit | same |
| HallucinationFilter repeated word detection | Unit | same |
| HallucinationFilter passes valid text | Unit | same |
| WhisperKitSTTService model path resolution | Unit | `Tests/VoxFlowAppTests/WhisperKitSTTServiceTests.swift` |
| STTBackend enum codable round-trip with new case | Unit | `Tests/VoxFlowAppTests/AppModelTests.swift` |
| PCM Int16 → Float conversion correctness | Unit | `Tests/VoxFlowAppTests/WhisperKitSTTServiceTests.swift` |

Note: Full WhisperKit transcription tests require the model to be present and are manual/integration tests, not unit tests.

## Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Swift 6.2 strict concurrency warnings from WhisperKit | Low | WhisperKit v0.14.1+ has Sendable conformance; suppress remaining warnings with `@preconcurrency import` |
| First-run ANE compilation delay (10-30s) | Low | Show progress in status line during warmup |
| Model not pre-downloaded | Low | Clear error message pointing to download script |
| WhisperKit SPM dependency increases build time | Low | One-time cost; WhisperKit builds quickly |
| M4 Pro initialization hang (Issue #340) | Low | Monitor; keep Python Whisper as fallback backend |

## Privacy Guarantee

WhisperKit configured with `modelFolder:` + `download: false` makes **zero network calls**. All inference is local CoreML on ANE. No audio, text, or telemetry leaves the device. Verified by source code audit of WhisperKit v0.15.0.
