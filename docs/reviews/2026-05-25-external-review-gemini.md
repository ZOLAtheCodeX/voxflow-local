# Archived External Reviews — Gemini Antigravity IDE

- **Date received:** 2026-05-25 (two rounds)
- **Source:**
  - Round 1 — initial codebase review: `~/.gemini/antigravity-ide/brain/1327ee64-e201-4092-b9e0-3b5130376ebb/analysis_results.md`
  - Round 2 — roadmap review: `~/.gemini/antigravity-ide/brain/1327ee64-e201-4092-b9e0-3b5130376ebb/roadmap_review.md`
- **Status:** Both rounds read, verified, folded into `docs/plans/2026-05-25-stabilization-modernization-roadmap.md`. Original artifacts left in place; this file is the project-local copy of record.

## Round 2 — Roadmap Review (2026-05-25, after gemma4 correction)

The reviewer was working from the gemma3-named version of my roadmap (their suggestions reference `gemma3:4b` / `gemma3:1b`). I had already updated to Gemma 4 in the prior turn after the user flagged the Ollama library page. The reviewer's *principles* still apply; the specific model names were translated to Gemma 4 equivalents.

| Item | Verdict | Rationale |
| --- | --- | --- |
| QW-8 attosecond divisor is correct as-is (`10^15`); my roadmap's "fix" would be wrong | **Accept** | Independently verified: 1 ms = 10^15 attoseconds. The original code-explorer agent's "bug" flag was wrong; I propagated it. Roadmap corrected. |
| Use Ollama `/api/pull` NDJSON streaming for model pull, not shell-out | **Accept** | Better UX, no CLI dependency. Backend proxies stream → Swift renders native `ProgressView`. Roadmap Phase 3.3 rewritten. |
| Dynamic model default based on host RAM (was `gemma3:4b` ≥16 GB / `gemma3:1b` <16 GB) | **Accept the principle** | Translated to Gemma 4: `gemma4:e4b-mlx` ≥16 GB, `gemma4:e2b-mlx` 8–16 GB, regex-only <8 GB. Thresholds refined in Phase 3.4. |
| Remove FLAN-T5 cleanly in Phase 3.5, no transition period | **Accept** | Regex `apply_tone(light_cleanup())` is already the guardrail fallback; FLAN-T5 is a mid-quality tier that's not worth 300 MB RSS. Roadmap Phase 3.5 updated. |

### Minor pushback recorded but not blocking

Reviewer proposed proxying `/api/pull` through the Python backend specifically. Swift could call Ollama directly (both are localhost) and skip a hop. Both work; backend proxy chosen for consistent error handling and the ability to warm the model server-side immediately after pull completes.

---

## Round 1 — Initial Codebase Review

## Verification Result

All three findings reproduced against current code (commit `51d6160`). Severity reclassified after independent review.

| # | Finding | External severity | Verified | Reclassified severity | Roadmap phase |
|---|---|---|---|---|---|
| 1 | Hallucination filter drift (♫, ♬, … missing in Python) | Critical | Yes — `HallucinationFilter.swift:18-24` vs `server.py:939-942` | Low (only affects Python `whisper` backend, not default WhisperKit path) | Phase 1 — Quick wins |
| 2 | Design token drift in `SetupWizardView`, `SettingsView`, `DashboardWindowView` | Medium | Yes — 30+ `.font(.system(size:))` literals confirmed via grep | Medium (matches own UI agent finding; subset of broader modernization) | Phase 4 — UI modernization |
| 3 | Sendable closure warning at `BackendProcessManager.swift:171:31` | Medium | Yes — reproduces on touch-rebuild with `swift build`; masked by incremental builds | Medium (real warning; proposed fix is functional but extracting to a named method is cleaner) | Phase 1 — Quick wins |

## Gaps Noted

External review did **not** surface, and these were added by independent review:

- `BackendProcessManager.stopOnWorkQueue` busy-spins (deadlock risk) — same file as Finding 3
- `GlobalHotkeyService` ↔ `FnHoldHotkeyService` pattern mismatch on Carbon callbacks
- Sync ML inference on FastAPI async event loop (no concurrency cap)
- Pydantic text-input models without `max_length` (large-payload exposure)
- `PrivateAPIClient` blocking `urllib` calls (20–40s timeouts)
- Scoping for Gemma/Ollama swap: FLAN-T5 is used in exactly one function (`PolishEngine.polish`)
- "Gemma 4" naming — does not exist publicly as of 2026-Q2; target should be Gemma 3
- `AppState` has 50+ `@Published` properties (god-object pattern)
- `processDictation` workflow still inline in `AppCoordinator` while peers were extracted
- `simulatePaste` clipboard restore via `DispatchQueue.main.asyncAfter` inside async context (cancellation race)
- `elapsedMilliseconds` helper duplicated in 3 files, with attoseconds arithmetic dividing by 10^15 instead of 10^12
- Whisper `chunk_length_s=30` + `stride=[5,1]` adds ~6s padding overhead per short dictation utterance

## Original Findings — Full Text

(Original 147-line artifact preserved below for reference.)

---

### Original Executive Summary

> VoxFlow Local is a macOS-native, on-device dictation application consisting of a SwiftUI-based menu bar frontend and a Python FastAPI backend. It offers on-device machine learning inference (WhisperKit, Whisper-Small, TranslateGemma/Marian, and FLAN-T5-Small) for dictation, translation, meeting summary, and LLM prompting.
>
> Overall, the codebase is exceptionally clean, well-structured, and highly mature. It implements robust architecture patterns, maintains strict isolation of UI and worker threads, handles security with keychains, and utilizes modern Swift 6 paradigms. Furthermore, the codebase is supported by a comprehensive test suite of 547 tests (256 Swift, 281 Python, and 10 regression tests), all of which pass successfully.

### Original Finding 1 — Hallucination Filter Drift

Swift `HallucinationFilter.swift:18-24` filters `\u{266A}`, `\u{266B}`, `\u{266C}`, `...`, `\u{2026}`. Python `server.py:939-942` filters only `"♪"`, `"♪♪"`, `"♪♪♪"`, `"..."`. Recommended addition to Python list: `"♫"`, `"♬"`, `"…"`.

### Original Finding 2 — UI Design Token Drift

`SetupWizardView.swift`, `SettingsView.swift`, and `DashboardWindowView.swift` hardcode font sizes, spacings, and corner radii instead of consuming `VF` tokens defined in `VFDesignTokens.swift`.

### Original Finding 3 — Swift 6 Concurrency Warning

```
Sources/VoxFlowApp/Services/BackendProcessManager.swift:171:31:
warning: reference to captured var 'self' in concurrently-executing code
[#SendableClosureCaptures]
```

Proposed fix: add `[weak self]` to the inner `.async` closure. Project-local refinement: extract the closure body to a private `handleUnexpectedExit(_:configuration:)` method.

### Original Action Plan

1. Update `_WHISPER_HALLUCINATION_ALWAYS` in `server.py` to sync with `HallucinationFilter.swift`
2. Apply `[weak self]` capture fix on line 170 of `BackendProcessManager.swift`
3. Consolidate styling in `SettingsView.swift`, `SetupWizardView.swift`, `DashboardWindowView.swift` to use `VF` tokens
