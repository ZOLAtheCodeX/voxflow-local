# VoxFlow Local — Next Session Roadmap

> Running list of improvements, enhancements, and research items.
> Last updated: 2026-02-22

---

## Priority 1: Latency & STT Upgrade

### Research: WhisperKit (Native Swift STT)
- **What:** Replace Python Whisper backend with [WhisperKit](https://github.com/argmaxinc/WhisperKit) — native Swift, Apple Neural Engine optimized
- **Why:** Eliminates HTTP roundtrip + Python overhead. 0.46s latency, 2.2% WER (best accuracy)
- **Impact:** Major latency reduction, simpler architecture (no Python needed for STT)
- **Risk:** Tight coupling to Apple Silicon; need to verify Swift Package Manager integration
- **Action:** Prototype WhisperKit integration, benchmark against current Whisper-Small

### Research: Moonshine v2 (Ultra-Fast Edge STT)
- **What:** Evaluate [Moonshine v2](https://arxiv.org/abs/2602.12241) models (Tiny: 26MB, Small: ~100MB)
- **Why:** 50ms latency (Tiny), streaming-capable, 5.8x faster than Whisper Tiny
- **Impact:** Sub-100ms transcription, enables real-time streaming partial results
- **Risk:** Newer model, less battle-tested; need to verify Apple Silicon support via MLX or ONNX
- **Action:** Download Moonshine v2 Tiny, benchmark on Mac, compare accuracy vs Whisper-Small

### Research: MLX Audio Framework
- **What:** Evaluate [mlx-audio](https://github.com/Blaizzy/mlx-audio) as STT runtime
- **Why:** Apple's native ML framework, 40% faster than PyTorch on Apple Silicon
- **Impact:** Could run Moonshine or Parakeet models with Apple-native optimization
- **Action:** Test mlx-audio STT pipeline, measure latency vs current PyTorch/MPS

---

## Priority 2: App Stability & Focus Bug

### Problem: VoxFlow Window Steals Focus
When VoxFlow's panel is open (watching transcription counter, recording indicator), it becomes the
frontmost app. `simulatePaste` then sends Cmd+V to VoxFlow itself instead of the target app.

### Root Cause
VoxFlow's SwiftUI window/panel activates on click, becoming `NSWorkspace.shared.frontmostApplication`.
The target app is captured at insertion time, not at recording start.

### Proposed Fixes (pick one or combine)
1. **Non-activating panel:** Use `NSPanel` with `.nonactivatingPanel` style mask so VoxFlow never
   steals focus from the target app, even when the user interacts with its UI.
2. **Capture target at recording start:** Store `targetApp` when Fn is pressed (before transcription),
   not when insertion happens (after transcription). Already partially implemented but needs hardening.
3. **Window-level focus bypass:** Set VoxFlow's window level to `.floating` with non-activating behavior
   so it overlays without taking focus.

### Goal
User can watch VoxFlow's live transcription counter and recording indicator while dictating,
and text still inserts into the correct target app.

---

## Priority 3: Fix Extended Dictation (>10 seconds)

### Problem
Dictation struggles after ~10 seconds. Target window is 30-45 seconds.

### Root Causes to Investigate
1. **Audio buffer or timing:** Something in the capture → transcribe pipeline drops or truncates
   audio around 10s. Debug `AudioCaptureService` buffer accumulation and HTTP payload size.
2. **Whisper 30-second context window:** Audio beyond 30s needs chunking. Backend may not chunk.
3. **HTTP timeout:** `BackendAPIClient` timeout may be too short for larger payloads.

### Proposed Fix
- Debug the 10-second cutoff first (likely a buffer, timeout, or base64 payload issue)
- Implement server-side audio chunking (25-30s segments) for the 30-45s target
- Add progress feedback to Swift frontend during long transcriptions

---

## Priority 4: Clear History Feature

### Problem
No way to clear recorded dictation history from the app.

### Implementation
- Add "Clear History" to Settings or Recent tab
- Options: Clear today / this week / this month / all time
- Clears `recentDictations` in `SessionMemoryStore` (ring buffer)
- Also reset dashboard metrics (`resetDashboardMetrics()` already exists)
- Confirm before clearing (destructive action)

---

## Priority 6: UX Enhancements

### Problem
FLAN-T5-Small (60M params) echoes input unchanged. Currently falls back to regex-based light_cleanup.

### Options
| Model | Size | Quality | Notes |
|-------|------|---------|-------|
| FLAN-T5-Base | 990 MB | Moderate | 4x larger, may actually rewrite |
| Phi-3-mini (3.8B) | ~2.5 GB | High | Strong instruction following |
| Gemma-2B | ~1.5 GB | Good | Google's small LLM |
| SmolLM2-1.7B | ~1.2 GB | Good | HuggingFace's efficient small LLM |

### Recommendation
Evaluate SmolLM2-1.7B or Gemma-2B via MLX for polish mode. Both are small enough for on-device with meaningful text rewriting capability.

---

## Priority 5: Polish Mode — Better Cleanup Model

### Per-App Profiles
- Auto-select tone/cleanup mode based on target app bundle ID
- Formal for email (Mail, Outlook), raw for terminal, concise for Slack
- Infrastructure already exists: `appToneOverrides` in AppState

### Voice Commands
- Detect command phrases: "delete that", "new line", "select all", "undo"
- Route to action instead of text insertion
- Requires a classifier step before insertion

### Confidence Indicator
- Show transcription confidence in menu bar status line
- Backend already returns `confidence_estimate` — surface it in UI
- Color-code: green (>0.8), yellow (0.5-0.8), red (<0.5)

### Streaming Partial Results
- If using Moonshine v2 or WhisperKit streaming mode, show partial transcript while user is still speaking
- Requires WebSocket or SSE connection instead of single HTTP POST

---

## Priority 7: App Publishing & Distribution

### Goal
Package VoxFlow for distribution — stable, signed, installable .app bundle.

### Items
- Code-sign with Apple Developer ID (not just ad-hoc)
- Create DMG installer or use Sparkle for auto-updates
- Notarize for Gatekeeper approval
- Polish onboarding flow (accessibility permission prompt, mic permission)
- Create landing page / GitHub release

---

## Completed (2026-02-21/22)

- [x] Fix capture for Electron apps (Notion, Codex) — `.anyApp` targeting mode
- [x] Client-side 16kHz audio resampling via AVAudioConverter
- [x] Target app activation before paste (Electron timing fix)
- [x] Two-tier Whisper hallucination filter
- [x] Default to raw insertion (bypass FLAN-T5)
- [x] Verified AX insertion (detect false .success from kAXSelectedTextAttribute)
- [x] Polish echo fallback to light_cleanup
- [x] Diagnostic logging at all pipeline guards
- [x] Removed unused Voxtral-Mini-3B model (saved 17 GB)

---

## Decision: Gemini Models

**Verdict: Not suitable.** Gemini STT/TTS models are cloud-only (Google AI Studio, Vertex AI). VoxFlow's architecture is privacy-first, fully local. No on-device Gemini STT models are available.

---

## Sources

- [WhisperKit — Apple Silicon ASR](https://github.com/argmaxinc/WhisperKit)
- [Moonshine v2 — Streaming Edge ASR (Feb 2026)](https://arxiv.org/abs/2602.12241)
- [Moonshine GitHub](https://github.com/moonshine-ai/moonshine)
- [MLX Audio — Apple Silicon STT/TTS](https://github.com/Blaizzy/mlx-audio)
- [Best Open Source STT Models 2026 — Northflank Benchmarks](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks)
- [WhisperKit Benchmarks](https://github.com/argmaxinc/WhisperKit/blob/main/BENCHMARKS.md)
