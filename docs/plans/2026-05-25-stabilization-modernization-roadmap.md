# Stabilization & Modernization Roadmap

- **Date:** 2026-05-25
- **Branch baseline:** `master` @ `51d6160`
- **Test baseline:** 537 reported in CLAUDE.md; pytest actually collects 281 Python tests (parametrization expands the count). True total: 256 Swift + 281 Python + 10 regression = 547.
- **Current test totals (post-Phase-5):** 256 Swift + 344 Python (+9 live-Ollama skipped without `VOXFLOW_OLLAMA_GOLDEN=1`).
- **Inputs:**
  - 4-agent parallel codebase review (Swift architecture, Python backend, SwiftUI, Ollama swap scoping)
  - External review from Gemini Antigravity IDE, verified and archived at `docs/reviews/2026-05-25-external-review-gemini.md`

## Shipping Status (as of 2026-05-26)

| Phase | Status | Branch | Notes |
| --- | --- | --- | --- |
| Phase 1 — Quick Wins (QW-1..8) | ✅ Shipped | `master` (commit `b04badd`) | All 8 quick wins merged before this roadmap exited draft. |
| Phase 2 — Decompose & Test | ⚠️ Partial | `feature/phase-2-decompose` | (tasks 1–4 committed: `c85c933` nlp, `6325c23` privacy, `79617fa` engines, `1b2dac6` routing + schemas). Task 5 (api/ extraction) stashed — 4 privacy-token tests fail under it. Tasks 6–14 (Swift coordinator extraction + concurrency hardening + new tests) deferred. |
| Phase 3 — Ollama / Gemma 4 Polish | ✅ Shipped | `feature/phase-3-ollama` (tip `370d74c`) | All 5 sub-phases (3.1–3.5) complete; FLAN-T5 fully removed; OllamaBackend is the only polish backend; regex `apply_tone(light_cleanup())` is the documented unavailability fallback. PHASE_3_COMPLETE emitted 2026-05-26. Local-validation owed to user: run `scripts/measure_polish_latency.py` with Ollama up to fill in real latency numbers, and `VOXFLOW_OLLAMA_GOLDEN=1 pytest backend/tests/test_polish_golden.py` to confirm <15% guardrail trigger rate on this user's hardware. |
| Phase 4 — UI Modernization | ✅ Shipped | `feature/phase-4-ui` (tip `e698e23`) | Translucent panel + materials sweep + token-driven typography/colors/motion + 4-step `StagedProgressView` + target-app indicator + conditional Settings fields + Skip Calibration + `ConfidenceBadge` a11y + T0·M0 expansion + shared `MetricCardView`. Zero hardcoded `.font(.system(size:))` in `SetupWizardView/SettingsView/DashboardWindowView` (was 79). Zero `Color.gray.opacity` in `Sources/VoxFlowApp/Views/`. PHASE_4_COMPLETE emitted 2026-05-26. |
| Phase 5 — Performance Polish | ⏳ In-flight | `feature/phase-5-perf` | (5.1 short-audio whisper fast path, 5.2 Luhn-validated CC redaction, 5.3 lock-guarded rate limiter, 5.4 WebSocket idle timeout, 5.5 FocusContextMonitor frozen-poll short-circuit — all committed). 5.7/5.8 docs (this revision). |

Phase 5.6 (`AppState` `BackendReadinessState` collapse) overlaps with deferred Phase 2 Task 8 — likely lands as part of the Phase 2 closeout rather than Phase 5.

## Goals (from user)

1. Stabilize — fix "sometimes buggy" behavior
2. Replace text polish model (FLAN-T5-Small → Gemma 4 via Ollama)
3. Improve performance — faster, more effective
4. Modernize UI — feel native to macOS Sequoia

## Key Discoveries

- **FLAN-T5 is used in exactly one function** (`PolishEngine.polish` at `server.py:618-644`). Translation already uses TranslateGemma. Meeting summarization and prompt framing are rule-based. The model swap touches one class, not the whole backend.
- **Gemma 4 is live on Ollama as of 2026-Q2.** Edge variants are designed for on-device use; MLX builds are Apple Silicon optimized. For VoxFlow polish on M-series:
  - `gemma4:e2b-mlx` — 7.1 GB, 128K ctx, text-only, MLX (low-latency)
  - `gemma4:e4b-mlx` — 9.6 GB, 128K ctx, text-only, MLX (recommended default for quality)
- **The two highest-leverage UI changes are tiny patches**: translucent menu bar panel (`MenuBarPanelController.swift:49-51`, ~5 lines) and replacing `Color.gray.opacity(0.08)` with `.quaternary` materials across 7 view files.
- **"Sometimes buggy" likely traces to two issues**: `BackendProcessManager.stopOnWorkQueue` busy-spins the work queue during shutdown (deadlock risk on rapid stop/start), and FastAPI sync handlers run ML inference on the threadpool with no concurrency cap.

---

## Phase 1 — Quick Wins (~1 day) ✅ Shipped (`master` @ `b04badd`)

High-confidence, small-blast-radius fixes. Ship as one PR. Includes the two viable external-review items plus the highest-severity issues independent review surfaced in the same file.

| ID | File:line | Change | Effort |
| --- | --- | --- | --- |
| QW-1 | `server.py:939-942` | Add `"♫"`, `"♬"`, `"…"` to `_WHISPER_HALLUCINATION_ALWAYS`; add a parity unit test that fails if either side drifts | 15m |
| QW-2 | `BackendProcessManager.swift:168-187` | Extract crash-restart body to `handleUnexpectedExit(_:configuration:)`; eliminates Sendable warning at `:171:31` and creates a unit-testable seam | 45m |
| QW-3 | `BackendProcessManager.swift:208-218` | Replace `while process.isRunning && Date() < deadline { usleep(100_000) }` with `process.terminationHandler` + deadline-driven follow-up. Frees `workQueue` during shutdown; eliminates deadlock against `syncOnWorkQueue` from main | 2h |
| QW-4 | `server.py` Pydantic models (`CleanupRequest.input_text`, `TranslateRequest.source_text`, `MeetingRequest.transcript`) | Add `Field(max_length=50_000)` | 30m |
| QW-5 | `AccessibilityInsertService.swift:109-115` | Replace `DispatchQueue.main.asyncAfter` with `await Task.sleep`. Cancellation-safe; clipboard restore no longer orphaned if Task cancels mid-paste | 30m |
| QW-6 | `CommandPaletteView.swift:646-660` | Replace `Timer.scheduledTimer` with `.task` lifecycle. Auto-cancels on view disappear; no leak if panel closes mid-transcription | 30m |
| QW-7 | `AppCoordinator.swift:733` (`selectToneStyle`) | Store the spawned `Task` handle; cancel on `startCapture()` to avoid stale transcript overwrite | 30m |
| QW-8 | `AppCoordinator.swift:67-71`, `TextInsertionCoordinator.swift:156-160`, `WhisperKitSTTService.swift:134-138` | Consolidate `elapsedMilliseconds` into one helper on `ContinuousClock.Instant`. (Note: arithmetic `attoseconds / 10^15` is correct — 1 ms = 10^15 attoseconds. Original "bug" flag was wrong.) | 30m |

**Acceptance:** existing test suite green; new hallucination-parity test green; backend stop/start cycle on rapid hotkey toggling no longer hangs.

---

## Phase 2 — Decompose & Test (~1 week) ⚠️ Partial (tasks 1–4 of 5 committed on `feature/phase-2-decompose`; task 5 stashed)

Tighten the structure so subsequent phases land cleanly.

### Python: split `server.py` (2274 lines → 5 modules)

- `backend/app/engines/` — `WhisperEngine`, `PolishEngine`, `TranslateEngine`
- `backend/app/privacy/` — `ConsentStore`, `AuditLogger`, `redact_sensitive_text`
- `backend/app/routing/` — `ProviderRouter`, `PrivateAPIClient`
- `backend/app/nlp/` — `light_cleanup`, `apply_tone`, sentence/speaker/meeting helpers
- `backend/app/api/` — FastAPI route handlers + middleware (thin layer)

### Swift: finish coordinator extraction

- Extract `DictationWorkflowCoordinator` from `AppCoordinator.swift:1081-1206`
- Add shared `autoInsertOrReview(_:mode:trace:)` helper to consolidate duplicated auto-insert blocks
- Collapse 8 backend-readiness `@Published` properties on `AppState` into a single `BackendReadinessState` struct (one coalesced publish, fewer re-renders)

### Concurrency

- Wrap ML inference calls in `run_in_executor` with `asyncio.Semaphore(2)` cap. Add 503 response when saturated. Document the single-flight assumption.
- Replace `PrivateAPIClient` `urllib` calls with `httpx.AsyncClient` (or move to executor with thread-level timeout)
- Align `GlobalHotkeyService` and `FnHoldHotkeyService` on a single Carbon-callback pattern; document the invariant

### Tests

- Add unit tests for `FnHoldHotkeyService` debounce logic
- Add unit tests for `BackendProcessManager` auto-restart state machine (now testable after QW-2 extraction)
- Replace `AppCoordinatorSmokeTests` (which test `AppState` boolean logic, not coordinator behavior) with coordinator-driven tests

---

## Phase 3 — Ollama / Gemma 4 Polish Backend (~11 hours, sequential) ✅ Shipped (`feature/phase-3-ollama` @ `370d74c`)

### Architecture

Add a minimal `TextLLMBackend` Protocol (duck-typed). Two implementations:

- `FlanT5Backend` — wraps current `PolishEngine` logic unchanged
- `OllamaBackend` — POSTs to `http://localhost:11434/v1/chat/completions` via stdlib `urllib` (zero new dependencies)

Selector: `VOXFLOW_POLISH_BACKEND` env var (`flan_t5` | `ollama`; default `flan_t5` during validation, switchover to `ollama` after Phase 3.4).

Guardrail (`_guardrail_triggered`) stays in `PolishEngine` and wraps both backends.

### Model selection

Default is **RAM-tiered** at first run, then user-overridable in Settings:

| Detected host RAM | Default model | Disk | Rationale |
| --- | --- | --- | --- |
| ≥ 16 GB | `gemma4:e4b-mlx` | 9.6 GB | Best quality on Apple Silicon |
| 8–16 GB | `gemma4:e2b-mlx` | 7.1 GB | Lower memory pressure |
| < 8 GB | Regex pipeline only | 0 | Don't recommend Ollama; degrade gracefully |

Rationale for MLX variants over the standard ones: MLX builds use Apple's MLX framework directly, bypassing the generic GGML path that the standard Ollama variants use. Faster on M-series, especially first-token latency. The text-only constraint is acceptable — dictation polish doesn't need vision.

If the user wants the multimodal variant (e.g., for a future "describe what's on screen" feature), `gemma4:e4b` (9.6 GB, text+image) is the equivalent. Out of scope for this phase.

Note: RAM detection should use `ProcessInfo.processInfo.physicalMemory` from Swift; the value passes to backend at startup or is queried by backend via `sysctl hw.memsize`. Treat thresholds as starting points to refine in Phase 3.4.

### Sub-phases

| # | Effort | Work |
| --- | --- | --- |
| 3.1 | S (~2h) | Add `OllamaBackend` class. Chat-format system prompt: "You clean up dictated speech. Return only the cleaned text, no explanation, no preamble." Per-tone constraint in system role, not user role. Unit tests with mocked Ollama response. |
| 3.2 | S (~1h) | `/v1/ready` reports `ollama_available: bool`. Swift surfaces one-time nudge in Settings: "Ollama not detected — install for higher-quality polish." Non-blocking. |
| 3.3 | M (~3h) | Settings → "Local AI Model" section. Status pill (Ollama installed / model pulled / current model). "Pull model" button hits Ollama's `/api/pull` endpoint (NDJSON streaming progress with `completed`/`total` per chunk) — backend proxies the stream to Swift, which renders a native `ProgressView`. Default model is RAM-tiered (see below). `VOXFLOW_OLLAMA_MODEL` env var still overrides. **Never auto-pull.** |
| 3.4 | M (~4h) | 5–10 golden polish regression tests in `backend/tests/`. Tune system prompt against test set until guardrail trigger rate < 15%. Empirically measure latency for both `e2b-mlx` and `e4b-mlx` on the dev machine and document. Flip `VOXFLOW_POLISH_BACKEND` default to `ollama`. |
| 3.5 | S (~1h) | Remove FLAN-T5 path entirely — class, weights download, env var, lazy load. The regex `apply_tone(light_cleanup())` pipeline is already the guardrail-fallback when Ollama returns degenerate output; an additional mid-quality 300 MB model tier is dead weight. Drops ~300 MB from process RSS and ~150 MB from disk. |

### Performance expectation (Apple Silicon — to be confirmed in Phase 3.4)

| Model | Disk | First call | Steady-state polish (20–50 words) | Quality vs FLAN-T5 |
| --- | --- | --- | --- | --- |
| FLAN-T5-Small (current) | ~300 MB | 3–5s (MPS load) | 400–800ms | baseline |
| `gemma4:e2b-mlx` | 7.1 GB | ~5–8s (first only) | ~300–600ms (estimate; confirm) | meaningfully better |
| `gemma4:e4b-mlx` | 9.6 GB | ~8–12s (first only) | ~700ms–1.5s (estimate; confirm) | substantially better — recommended default |

Latency estimates are extrapolations from comparable parameter counts on M-series with MLX. Phase 3.4 must measure on-device before defaulting.

### Risks & mitigations

1. **Ollama not running** → `OllamaBackend.polish()` catches connection errors and falls back to `apply_tone(light_cleanup())`. Never let unavailability surface as 500.
2. **Gemma verbosity** → guardrail length ceiling may trip too aggressively; relax for Ollama backend only.
3. **First-run cold start** → document; Ollama keeps model resident for 5 min after last call.
4. **Disk footprint** → `gemma4:e4b-mlx` is ~9.6 GB on top of existing ~1.5 GB Whisper/WhisperKit footprint. Total project model footprint becomes ~11 GB. User-initiated pull only; offer `gemma4:e2b-mlx` (~7.1 GB) as a documented lighter alternative.
5. **MLX variant availability** → MLX builds are text-only. If a future feature needs vision input, the swap is one env var to the non-MLX variant.

---

## Phase 4 — UI Modernization (~2 days) ✅ Shipped (`feature/phase-4-ui` @ `e698e23`)

Two high-leverage visual changes first, then expand the design system.

### Headliners

| Item | File:line | Change |
| --- | --- | --- |
| Translucent panel | `MenuBarPanelController.swift:49-51` | `panel.isOpaque = false`; `panel.backgroundColor = .clear`; wrap SwiftUI root in `.background(.ultraThinMaterial)` with `cornerRadius: 12`. Single biggest visual delta. |
| Materials sweep | `SetupWizardView.swift:62-64, 105-107, 163-165, 237-239`; `DashboardWindowView.swift:91-92, 107-108, 133-134, 158-160, 194-195`; `OnboardingCalibrationView.swift:25-27` | Replace `Color.gray.opacity(0.08/0.10)` with `.quaternary` (or `.regularMaterial` for elevated emphasis). Adapts to dark mode + accent color. |

### Strengthen `VFDesignTokens.swift`

Currently: 4 font sizes, 3 corner radii, 3 spacing steps. Missing:

- Semantic colors: `VF.colorSuccess`, `VF.colorWarning`, `VF.colorError`, `VF.colorNeutral` (six view files each define their own `backendStatusColor`)
- Motion: `VF.animationStandard = Animation.smooth(duration: 0.25)`, `VF.animationPulse` for waveform/badge

Then enforce in `SetupWizardView`, `SettingsView`, `DashboardWindowView`, which currently ignore the token file entirely (30+ `.font(.system(size:))` literals — verified via grep). This is the external review's Finding 2, scaled to its actual reach.

### UX wins

| Item | File:line | Change | Effort |
| --- | --- | --- | --- |
| Stage progress | `CommandPaletteView.swift:627-644` | Replace plain `ProgressView()` + elapsed timer with a four-step labeled progress: capture → transcribe → cleanup → insert | M |
| Target app indicator | `CommandPaletteView.swift:595-625` | Inside `recordingStateCard`, show `arrow.right.circle` + "Inserting into \(capturedTargetApp?.localizedName)" | S |
| Conditional Settings fields | `SettingsView.swift:119-171` | Hide OpenAI fields unless `state.sttBackend == .openAI`; hide local Whisper model unless `.whisper` | S |
| Skip Calibration | `OnboardingCalibrationView.swift:35-51` | Add secondary `.bordered` "Skip Calibration" button | S |
| `ConfidenceBadge` a11y | `ConfidenceBadge.swift:6-15` | `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Confidence \(percent) percent")` | S |
| Replace `T0·M0` | `DashboardPanelView.swift:38-43`; `DashboardWindowView.swift:52` | Expand abbreviations; extract shared `MetricCardView` | S |

---

## Phase 5 — Performance Polish (~1 day) ⏳ In-flight (`feature/phase-5-perf`; 5.1–5.5 committed)

| Item | File:line | Change |
| --- | --- | --- |
| Whisper chunking | `server.py:260-261` | Skip `chunk_length_s`/`stride_length_s` when audio < 20s. Removes ~6s of padding overhead per short dictation. |
| PolishEngine pre-warm | `server.py:1910-1913` | After Ollama swap this is moot; pre-Ollama, eagerly load FLAN-T5 at startup or surface "loading model" in `/v1/ready` so the cold-start hiccup is visible to the user. |
| FLAN-T5 removal | `server.py:574-672` | Phase 3.5 deletion. Drops ~300MB from process RSS. |
| `redact_sensitive_text` tightening | `server.py:876` | Add Luhn check on the 13–19 digit pattern, or document the conservative over-redaction. |
| Rate-limit lock | `server.py:1933, 1958-1961` | Add `threading.Lock` around `_rate_limit_timestamps`. Document single-worker assumption explicitly. |
| WebSocket timeout | `server.py:2257-2268` | `asyncio.wait_for(websocket.receive_text(), timeout=60)` to clean up zombie connections. |
| `FocusContextMonitor.poll` | `FocusContextMonitor.swift:48-56` | Move `isFrozen` check to top of `poll()` before `focusedTargetSnapshot()` call. Saves an `AXUIElementCopyAttributeValue` pair every 250ms during recording. |

---

## Sequencing Notes

- Phase 1 → Phase 2 → Phase 3 is strict. Don't start Ollama work until concurrency and decomposition are clean — easier to test the new backend behind a Protocol when the surrounding code is split into modules.
- Phase 4 (UI) and Phase 5 (perf) can interleave with Phase 3.
- Recommend creating a `feature/stabilize-and-modernize` branch off `master` and merging each phase as a separate PR for clean review history.

## What's Explicitly Out of Scope

- TranslateGemma replacement (already on a modern model; separate evaluation)
- Whisper STT replacement (working well; new finding-driven changes only)
- App publishing / notarization (P7 in CLAUDE.md memory; defer)
- Voice commands / streaming (P6; defer)
- Multi-worker FastAPI deployment (single-worker assumption is correct for a local app)

## Open Questions for Owner

1. ~~Is keeping the FLAN-T5 fallback worth the ~300 MB RSS, or remove cleanly in Phase 3.5?~~ → **Resolved (2026-05-25):** Remove cleanly. Regex pipeline is the fallback.
2. ~~Should "Pull gemma4:e4b-mlx" shell out, or copy command?~~ → **Resolved (2026-05-25):** Use Ollama's `/api/pull` NDJSON streaming endpoint, proxied through the FastAPI backend, rendered as a native `ProgressView` in Swift. Caveat: a direct Swift → localhost:11434 call would also work and skip the backend hop; reviewer's argument for backend proxy is consistent error handling + the backend can warm the model right after pull completes. Going with backend proxy.
3. ~~Default model?~~ → **Resolved (2026-05-25):** RAM-tiered (table in Phase 3 § Model selection). `e4b-mlx` ≥ 16 GB, `e2b-mlx` 8–16 GB, regex-only < 8 GB.

## Revision Log

- 2026-05-25 (initial) — drafted from 4-agent codebase review + Gemini external review
- 2026-05-25 (revision 1) — corrected Gemma 3 → Gemma 4 model names (Ollama library confirms availability of edge MLX variants)
- 2026-05-25 (revision 2) — second external review:
  - QW-8: removed incorrect "fix attoseconds arithmetic" claim. The original `10^15` divisor is correct.
  - Phase 3.3: switched from shell-out / clipboard to Ollama `/api/pull` NDJSON streaming through FastAPI proxy.
  - Phase 3 § Model selection: added RAM-tiered defaults.
  - Phase 3.5: removed transition period — FLAN-T5 deleted cleanly.
- 2026-05-26 (revision 3) — Ralph Loop iteration:
  - Phase 3 shipped on `feature/phase-3-ollama` (`370d74c`); PHASE_3_COMPLETE.
  - Phase 4 shipped on `feature/phase-4-ui` (`e698e23`); PHASE_4_COMPLETE.
  - Phase 5 work in-flight on `feature/phase-5-perf` (5.1–5.5 committed; 5.7/5.8 docs land with this revision).
  - Phase 2 Task 5 (api/ extraction) stashed pending fix to 4 failing privacy-token tests.
  - Added "Shipping Status" table at the top of this document so a reader can see at a glance which phases have landed without reading the whole plan.
