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
  Models/AppModels.swift        Domain types
  State/AppState.swift          @Published app state
  Views/                        SwiftUI views — VFDesignTokens.swift is the single source of truth for typography / colors / motion / materials

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
ollama pull gemma4:e4b-mlx        # ≥16 GB RAM (recommended) — or gemma4:e2b-mlx for 8–16 GB
```

If Ollama is unreachable, polish silently falls back to `apply_tone(light_cleanup())`.

### Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `VOXFLOW_MODELS_DIR` | Pre-downloaded model cache | `./models` |
| `VOXFLOW_BACKEND_URL` | Backend URL override (Swift) | `http://127.0.0.1:8765` |
| `VOXFLOW_STT_BACKEND` | `whisper` / `whisperKit` / `openai` | `whisperKit` |
| `VOXFLOW_WHISPER_MODEL` | Whisper model id | `openai/whisper-small` |
| `VOXFLOW_OLLAMA_URL` | Ollama base URL | `http://localhost:11434` |
| `VOXFLOW_OLLAMA_MODEL` | Polish model id | `gemma4:e4b-mlx` (RAM-tiered fallback to `e2b-mlx`) |
| `VOXFLOW_POLISH_BACKEND` | Polish selector (only `ollama` recognised post-3.5) | `ollama` |
| `VOXFLOW_SIGN_IDENTITY` | Code-signing identity override | auto-detected Apple Development cert |
| `VOXFLOW_OFFLINE` | Disable HF downloads | `1` |

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

### Python
- ConsentStore: 30-min TTL, thread-safe (`threading.Lock`); bounded-use tokens.
- Rate limiter: 120 req/60 s per IP, single-worker assumption, lock-guarded (Phase 5.3).
- PII redaction: credit cards Luhn-validated before `[ACCOUNT_NUMBER]` redaction (Phase 5.2).
- Whisper short-audio fast path: clips < 20 s skip the chunking + stride padding via per-call `chunk_length_s=0` (Phase 5.1).
- WebSocket `/v1/events` enforces a 60 s idle timeout with clean close frame (Phase 5.4).
- Polish engine wraps the selected `TextLLMBackend` (only Ollama post-3.5); guardrail + regex fallback live one layer up in `PolishEngine`.
- Logging: `logging.getLogger("voxflow")`; never bare `print()`.

## Testing

```bash
swift test                                              # ~256 Swift tests
./.venv/bin/python -m pytest backend/tests              # ~344 Python tests (+9 live-Ollama skipped)
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
| Polish output looks like raw light_cleanup | Ollama not running | `ollama serve && ollama pull gemma4:e4b-mlx`; check `/v1/ready` → `ollama_available` |
| Accessibility permission won't stick | Ad-hoc signing CDHash changes per rebuild | Use Apple Development cert; override with `VOXFLOW_SIGN_IDENTITY` |
| Accessibility shows "Missing" after granting | UI checked before user approved in System Settings | Click "Request" again — polling auto-updates within 2 s |

## Git
- Primary branch: `master`. Phase branches: `feature/phase-{N}-*`.
- Imperative commits with detailed body; `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` trailer.
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
- `codesign --sign -` (ad-hoc) for installed builds — use the auto-detected Apple Development cert.
- Reintroduce raw `.font(.system(size:))` literals in views or `Color.gray.opacity(...)` anywhere in `Sources/VoxFlowApp/Views/` — go through `VFDesignTokens.swift`.
- Skip `_RATE_LIMIT_LOCK` when touching `_rate_limit_timestamps` — short critical sections only.
