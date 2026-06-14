# VoxFlow Local — Project Conventions

## Overview

VoxFlow Local is a macOS-native dictation app: SwiftUI menu bar frontend + Python FastAPI backend. On-device ML: WhisperKit / Whisper-Small for STT, **Gemma 4 via local Ollama** for text polish (replaces the pre-Phase-3 FLAN-T5-Small path; regex pipeline is the fallback when Ollama is unreachable).

## Architecture

```
Sources/VoxFlowApp/             Swift frontend (SwiftUI, MenuBarExtra)
  AppCoordinator.swift          Central orchestrator (@MainActor)
  Services/                     Extracted coordinators + macOS-interop services
    SettingsCoordinator.swift           Provider, STT, tone, insert behavior + persistence
    OnboardingCoordinator.swift         Calibration flow lifecycle
    TextInsertionCoordinator.swift      Async AX insert + clipboard bridge + per-app stats
    TranslationWorkflowCoordinator.swift / PromptWorkflowCoordinator.swift
    PrivacyConsentCoordinator.swift     Privacy preview + closure-based continuation
    AccessibilityInsertService.swift    @MainActor AX text insertion + async paste fallback
    HallucinationFilter.swift           Two-tier Whisper hallucination filter (synced w/ backend)
    SessionMemoryStore.swift            Ring buffer for recent dictations
    MenuBarPanelController.swift        Non-activating NSPanel + NSStatusItem
    FocusContextMonitor.swift           Focused-target poller; frozen during capture
    CockpitCoordinator.swift            @MainActor cockpit orchestration — chip MRU + voice routing + insert/copy/undo
    LongFormSessionService.swift        State machine (idle → recording → reviewing) + JSON auto-save (~5 s)
    SmartActionService.swift            actor: smart-action backend dispatch + 20-entry undo history
    VoiceCommandRouter.swift            Single-keyword parser for in-review voice commands
  Models/AppModels.swift        Domain types — includes SmartActionId, AppliedAction, LongFormSession, LongFormState
  State/AppState.swift          @Published app state — cockpitVisible / cockpitSession / chipMRU / voicePromptStripDismissed
  Views/                        SwiftUI views — VFDesignTokens.swift is the single source of truth for typography / colors / motion / materials
    Cockpit/                    Cockpit Layer 0 views (TopBar, Transcript, ChipRow, SidePanel, Palette, VoicePromptStrip, KeyEventBridge)
    CockpitWindowView.swift     Top-level cockpit window — wires shortcuts ⌘R/⌘./⌘Z/⌘↩/⌘C/⌘\/⌘W/esc

backend/app/                    FastAPI server, decomposed in Phase 2
  server.py                     Composition root: app instance, middleware, route mounting, runtime singletons
  schemas.py                    All Pydantic request/response models
  engines/                      ML engines (Phase 2 + 3)
    whisper.py                  WhisperEngine (local HF pipeline) + OpenAIAudioClient (cloud fallback)
    llm_backend.py              TextLLMBackend Protocol + OllamaBackend + select_backend + Ollama admin helpers (list/pull/recommend)
    polish.py                   PolishEngine — guardrail + apply_tone(light_cleanup()) regex fallback
    translate.py                TranslateEngine (TranslateGemma / Marian)
    prompt_framing.py           PromptFramingEngine (intent + template)
    results.py                  STTExecutionResult dataclass
  nlp/                          Pure-Python cleanup + meeting analysis
    cleanup.py / tone.py / sentences.py / hallucination.py / meeting.py
  privacy/                      consent.py (ConsentStore, AuditLogger), redaction.py (Luhn-validated PII)
  routing/                      ProviderRouter, PrivateAPIClient, helpers
  text_cleanup_rules.py         Pre-compiled regex patterns shared with Swift

scripts/                        bootstrap / run / doctor / launcher / release + measure_polish_latency.py
models/                         Pre-downloaded ML models (~24 GB, not in git)
```

## Build & Run

```bash
swift build && swift run VoxFlowLocal      # frontend (requires backend running)
./scripts/bootstrap_backend.sh             # first-time venv setup
./scripts/run_backend.sh                   # uvicorn on 127.0.0.1:8765
```

- Swift 6.2 strict concurrency, macOS 14+ deployment target
- Python 3.11+; key deps: fastapi 0.116.1, uvicorn 0.35.0, torch 2.8.0, transformers 4.56.0
- Health: `curl http://127.0.0.1:8765/v1/health` · Readiness: `curl http://127.0.0.1:8765/v1/ready`

### Ollama (text polish)

```bash
# Install Ollama: https://ollama.com/download
ollama serve &
ollama pull gemma4:e2b-mlx        # 8–24 GB RAM (recommended) — gemma4:e4b-mlx only for ≥24 GB
```

R2 retune (2026-06-11, measured live): the 9 GB `gemma4:e4b-mlx` plus the Whisper backend thrashes a 16 GB machine (prompt eval ~5 tok/s, MLX runner wedges, ~28% of polish requests hit the 30 s timeout). Tier accordingly: `e2b-mlx` for 8–24 GB, `e4b-mlx` for ≥24 GB (`recommend_ollama_model` encodes this). The backend pins the model resident via per-request `keep_alive: "24h"` on the NATIVE `/api/chat` endpoint — the OpenAI-compat endpoint silently drops `keep_alive`, so never switch `OllamaBackend` back to it. `OLLAMA_KEEP_ALIVE` env tweaking is no longer needed. If the runner wedges (requests timing out warm), `ollama stop <model>` restores it.

If Ollama is unreachable, polish silently falls back to `apply_tone(light_cleanup())`. Same fallback fires when Ollama is reachable but the configured model isn't pulled — `/v1/ready` returns `ollama_available: true` either way (it probes the API socket only, not model presence).

### Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `VOXFLOW_MODELS_DIR` | Pre-downloaded model cache | `./models` |
| `VOXFLOW_BACKEND_URL` | Backend URL override (Swift) | `http://127.0.0.1:8765` |
| `VOXFLOW_STT_BACKEND` | `whisper` / `whisperKit` / `openai` | `whisperKit` |
| `VOXFLOW_WHISPER_MODEL` | Whisper model id | `openai/whisper-small` |
| `VOXFLOW_OLLAMA_URL` | Ollama base URL | `http://localhost:11434` |
| `VOXFLOW_OLLAMA_MODEL` | Polish model id override | auto: RAM-tier recommendation if pulled, else any pulled gemma4 (`resolve_default_ollama_model`) |
| `VOXFLOW_POLISH_BACKEND` | Polish selector (only `ollama` recognised post-3.5) | `ollama` |
| `VOXFLOW_SIGN_IDENTITY` | Code-signing identity override | auto-detected Apple Development cert |
| `VOXFLOW_OFFLINE` | Disable HF downloads | `1` |
| `VOXFLOW_ADOPT_FOREIGN_BACKEND` | `1` = app pairs with a manually run backend instead of reaping stamp-less listeners on 8765 (dev only) | unset |

## Key Patterns

### Swift
- `@MainActor` coordinator pattern. `AppCoordinator` orchestrates capture + workflow routing; extracted coordinators handle settings, onboarding, insertion, translation, prompt, privacy via protocol-typed properties.
- `processWithPrivacyGate` centralises the `privateAPI` vs `localOnly` branch for all four workflow processors.
- Per-app profile resolution via `resolveEffectiveProfile()` — never read `state.toneStyle` directly in workflow processors.
- Frozen target snapshot: `capturedTargetApp` is frozen at `startCapture()` and threaded to `insert(text:targetApp:)`. `FocusContextMonitor.poll()` short-circuits while `isFrozen` is set.
- Non-activating menu bar panel via `NSPanel(.nonactivatingPanel, .floating)` in `MenuBarPanelController`.
- Dynamic activation policy: `activateForWindow()` toggles `.regular`/`.accessory`. `LSUIElement = true` in Info.plist.
- WhisperKit native STT via `WhisperKitSTTService` with `WhisperKitConfig(modelFolder:, download: false)` — zero network.
- Swift-native cleanup + prompt framing (`TextCleanupService`, `PromptFramingService`) bypass the backend on the WhisperKit path.
- All typography, colors, motion presets, and material surfaces flow through `VFDesignTokens.swift` (`VF.*Font`, `VF.color*`, `VF.animation*`, `VF.cardBackground` / `VF.elevatedBackground` / `VF.panelMaterial`). Phase 4 eliminated raw `.font(.system(size:))` literals and `Color.gray.opacity(...)` from `SetupWizardView`, `SettingsView`, `DashboardWindowView`, and the `Views/` tree.
- Keychain for secrets (`KeychainService`); never UserDefaults.

### Cockpit (Layer 0)
- Long-form workspace opened via `⌥⌘V` (VoxFlow menu → "Open Cockpit"). Window scene `id: "cockpit"` in `VoxFlowLocalApp`.
- `LongFormSessionService` is a `@MainActor ObservableObject` with a 3-state machine — `.idle → .recording(startedAt:) → .reviewing` — and Codable `LongFormSession` persisted as JSON to `~/Library/Application Support/VoxFlow/sessions/`. Auto-save fires every ~5 s during recording. `appendChunk(_:)` inserts a `\n\n` paragraph break if ≥4 s of silence elapsed since the last chunk. `recoverLatestSession()` returns the most recently updated session for crash recovery.
- `SmartActionService` is an `actor` that wraps a `SmartActionBackend` and keeps a 20-entry undo stack (`AppliedAction`). Guardrail trips and unchanged echoes don't go on the stack — they aren't undoable. The default backend is `BackendAPISmartActionAdapter`, which POSTs to `/v1/smart_action`.
- `CockpitCoordinator` (@MainActor) routes chip taps + voice utterances + keyboard shortcuts. Chip MRU promotion threshold is 3 invocations (`promotionThreshold`); voice-prompt strip auto-dismisses after 10 review states (`voicePromptStripDismissThreshold`).
- `VoiceCommandRouter.parse(_:)` is intentionally simple: single keyword, trailing punctuation stripped, case-insensitive. Multi-word utterances return `.none` — Layer 0 ships memo/MECE/items/cancel/undo only.
- Six `SmartActionId`s ship in Layer 0: `.memo`, `.mece`, `.items`, `.steel` (steel-man), `.pyramid`, `.disclaimer`. System prompts live backend-side in `backend/app/smart_actions.py` (`_ACTION_DESCRIPTIONS` + `_SYSTEM_PROMPT_TEMPLATE`). Unknown `action_id` returns the transcript verbatim — never 5xx.
- Keyboard shortcuts (wired via `KeyEventBridge`): `⌘R` start, `⌘.` stop, `⌘Z` undo, `⌘↩` insert into target + close + reset, `⌘C` copy, `⌘\` toggle side panel, `⌘W` / esc close. Visible chips bind `⌘1`-`⌘6`; `⌘K` opens the full action palette.

### Python
- ConsentStore: 30-min TTL, thread-safe (`threading.Lock`); bounded-use tokens.
- Rate limiter: 120 req/60 s per IP, single-worker assumption, lock-guarded (Phase 5.3).
- PII redaction: credit cards Luhn-validated before `[ACCOUNT_NUMBER]` redaction (Phase 5.2).
- Whisper short-audio fast path: clips < 20 s skip the chunking + stride padding via per-call `chunk_length_s=0` (Phase 5.1).
- WebSocket `/v1/events` enforces a 60 s idle timeout with clean close frame (Phase 5.4).
- Polish engine executes the BYOM provider chain (R3): availability failures fall to the next provider, guardrail rejections fall straight to the regex floor, the floor is unconditional. `run()` returns `PolishOutcome` (text, guardrail_triggered, degraded_reason, served_by, model_id, fallback_depth); `polish()` is the 3-tuple compat wrapper. Cloud-bound payloads pass `redact_sensitive_text` first. Guardrail is word-level with tone-aware floors (R2.2).
- BYOM config: `~/Library/Application Support/VoxFlow/providers.json` (written by Swift `ProviderConfigStore`, read by the backend registry at launch; `VOXFLOW_PROVIDERS_CONFIG` dev override). Per-task chains: `polish`, `smart_action` — each task gets its OWN PolishEngine (`smart_action_polish_engine` in context.py). API keys live in the Keychain (`voxflow.provider.<id>`); the app injects them at backend launch as `VOXFLOW_PROVIDER_KEY_*` env vars named by `api_key_env` — never in the JSON file.
- `/v1/ready` reports `polish_chain`, per-provider `reachable`/`model_pulled` (closes the ready-but-missing-model blind spot), and `active_polish_provider`/`active_polish_model` — the Swift mode-in-use indicator (palette footer + cockpit pill) renders these; empty provider = regex fallback (orange). `/v1/providers/test` powers the Settings test-connection button.
- STT fallback chain is real (R3.5): dead local Whisper falls back to configured OpenAI STT; `stt_fallback_active` reports it.
- Logging: `logging.getLogger("voxflow")`; never bare `print()`.

## Testing

```bash
swift test                                              # ~449 Swift tests
./.venv/bin/python -m pytest backend/tests              # ~451 Python tests (+26 model/live-Ollama skipped)
./scripts/test_all.sh                                   # full suite
./scripts/test_all.sh --skip-runtime-checks             # skip regression-clip runtime checks
VOXFLOW_OLLAMA_GOLDEN=1 pytest backend/tests/test_polish_golden.py  # live Ollama acceptance
```

Backend golden clip fixtures: `backend/tests/fixtures/golden_clips/`. Polish golden set: `backend/tests/golden_polish_set.json`.

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Swift build fails with PCH path errors | Stale `.build` after project move | `rm -rf .build` |
| `ModuleNotFoundError: fastapi` | Broken venv | `rm -rf .venv && ./scripts/bootstrap_backend.sh` |
| `conditional downcast to CoreFoundation type` | Swift 6.2 CF bridging | `CFGetTypeID` guard + `as!`, not `as?` |
| Backend unreachable | Backend not running | `./scripts/run_backend.sh`; check port 8765 |
| Polish output looks like raw light_cleanup | Ollama unreachable, OR model not pulled | `ollama serve && ollama pull gemma4:e4b-mlx`; confirm pulled via `curl localhost:11434/api/tags` — `ollama_available` alone doesn't catch the missing-model case |
| Accessibility permission won't stick | Ad-hoc signing CDHash changes per rebuild | Use Apple Development cert; override with `VOXFLOW_SIGN_IDENTITY` |
| Accessibility shows "Missing" after granting | UI checked before user approved in System Settings | Click "Request" again — polling auto-updates within 2 s |

## Git
- Primary branch: `master`. Phase branches: `feature/phase-{N}-*`.
- Imperative commits with detailed body; Claude-assisted commits carry the standard `Co-Authored-By: Claude ... <noreply@anthropic.com>` trailer for whichever model did the work.
- `models/`, `.env`, credential files never committed.

## Do Not
- Move workflow routing logic out of `AppCoordinator`. Use forwarding methods on the AppCoordinator façade.
- Bypass `resolveEffectiveProfile()` — never read `state.toneStyle` directly in workflow processors.
- Store secrets in UserDefaults — use `KeychainService`.
- `URLSession.shared` — use `BackendAPIClient`'s configured session (has timeouts).
- Bare `except Exception: pass` in Python — always log via `logging.getLogger("voxflow")`.
- Hardcode absolute paths in scripts — use `BASH_SOURCE`-relative resolution.
- `NSApp.activate(ignoringOtherApps: true)` — go through `activateForWindow()`.
- `NSWorkspace.shared.frontmostApplication` at insert time — use the frozen `capturedTargetApp`.
- `WhisperKit()` default init — always pass `WhisperKitConfig(modelFolder:, download: false)`.
- Hardcode confidence in `WhisperEngine.transcribe()` — use `_estimate_confidence()`.
- Add hallucination-filter entries to only one side — keep `HallucinationFilter.swift` and `nlp/hallucination.py` in sync (parity test enforces).
- `Thread.sleep` in the insertion stack — use cooperative `Task.sleep`.
- Launch raw Mach-O for AX features — always `open ~/Applications/VoxFlow.app` so TCC sees a stable identity.
- `codesign --sign -` (ad-hoc) for installed builds *silently* — use the auto-detected Apple Development cert. Ad-hoc is allowed only as an explicit, loud opt-in (`VOXFLOW_ALLOW_ADHOC=1`) for forkers without an Apple ID; it does not persist the Accessibility grant across rebuilds.
- Reintroduce raw `.font(.system(size:))` literals in views or `Color.gray.opacity(...)` anywhere in `Sources/VoxFlowApp/Views/` — go through `VFDesignTokens.swift`.
- Skip `_RATE_LIMIT_LOCK` when touching `_rate_limit_timestamps` — short critical sections only.
- Push smart actions onto the cockpit undo stack when they fail the guardrail or return the transcript unchanged — `SmartActionService` filters those before recording history.
- Mutate `LongFormSession.transcript` from outside `LongFormSessionService` — `currentSession` is `@Published private(set)`. Use `setTranscript(_:)` so the auto-save Task sees the change.
- Construct real system-touching services in tests — use the seams: `TextInserting` for insertion, `BackendProcessRunning` + `BackendProcessRunnerFake` for process/port/PID-file. Two shipped incidents came from exactly this (ghost "hello" AX insertions; test-spawned uvicorn squatters on port 8765).
- Attach window-open notification listeners to a view — `.voxflowOpenCockpit`/`Dashboard`/`Setup` route through `AppCoordinator.installWindowOpenHandler` (app-lifetime); a view-bound `.onReceive` dies with its window and silently kills the ⌥⌘V hotkey.
- Edit `providers.json` schema on one side only — `ProviderConfigStore.swift` (writer) and `provider_registry.py` (reader) must stay in sync; the Swift `testFileSchemaMatchesBackendContract` pins the snake_case schema.
- Add a new `SmartActionId` to `AppModels.swift` without adding the matching system-prompt entry in `backend/app/smart_actions.py` — the engine will fall back to a generic prompt template and the action label/tooltip will look fine while the LLM output stays generic.
- Have the cockpit voice router fire actions while the session is `.recording` — voice keywords only resolve in `.reviewing`. Multi-word utterances must remain `.none` for Layer 0.
- Bypass `BackendAPISmartActionAdapter` to call `/v1/smart_action` directly from views — go through `CockpitCoordinator.applyAction` so MRU + undo stay correct.
