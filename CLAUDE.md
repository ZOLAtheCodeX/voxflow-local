# VoxFlow Local — Project Conventions

## Overview

VoxFlow Local is a macOS-native dictation app: SwiftUI menu bar frontend + Python FastAPI backend with on-device ML inference (Voxtral-Mini-3B, Whisper-Small, FLAN-T5-Small).

## Architecture

```
Sources/VoxFlowApp/        Swift frontend (SwiftUI, MenuBarExtra)
  AppCoordinator.swift      Central orchestrator (~510 lines, @MainActor)
  Services/                 Extracted coordinators + backend services
    SettingsCoordinator.swift           Provider, STT, insert behavior, app tone overrides + persistence
    OnboardingCoordinator.swift         Calibration flow lifecycle
    TextInsertionCoordinator.swift      AX insert, clipboard copy/bridge, per-app stats
    TranslationBenchmarkCoordinator.swift  Profile benchmarking + history
    PrivacyConsentCoordinator.swift     Privacy preview + closure-based continuation
    AccessibilityInsertService.swift    AX text insertion + bundleID-aware app info
    SessionMemoryStore.swift            Ring buffer for recent dictations (recent/push/count)
  Models/AppModels.swift    All domain types (enums, structs, InsertBehavior, FocusTargetSnapshot)
  State/AppState.swift      Published app state (~48 @Published properties)
  Views/                    SwiftUI views
backend/app/
  server.py                 FastAPI server (~1624 lines, all endpoints)
scripts/                    Shell scripts (bootstrap, run, doctor, launcher)
models/                     Pre-downloaded ML models (~24GB, not in git)
```

## Build & Run

### Swift Frontend

```bash
# Build
swift build

# Run (requires backend running)
swift run VoxFlowLocal
```

- **Swift 6.2** with strict concurrency
- **macOS 14+ (Sonoma)** deployment target
- Single executable target: `VoxFlowLocal`
- Package manager: Swift Package Manager (no Xcode project)

### Python Backend

```bash
# First time — create venv and install deps
./scripts/bootstrap_backend.sh

# Run backend (activates venv, starts uvicorn on 127.0.0.1:8765)
./scripts/run_backend.sh
```

- **Python 3.11+** required
- Key deps: fastapi 0.116.1, uvicorn 0.35.0, torch 2.8.0, transformers 4.56.0
- Backend binds to `127.0.0.1:8765` (localhost only)
- Health check: `curl http://127.0.0.1:8765/health`

### Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `VOXFLOW_MODELS_DIR` | Path to pre-downloaded models | `./models` |
| `VOXFLOW_BACKEND_URL` | Backend URL override (Swift) | `http://127.0.0.1:8765` |
| `VOXFLOW_BACKEND_PATH` | Backend server.py path override | auto-resolved |
| `VOXFLOW_PYTHON_PATH` | Python executable override | auto-resolved |
| `VOXFLOW_PROJECT_ROOT` | Project root override | auto-resolved |
| `VOXFLOW_STT_BACKEND` | STT engine: `voxtral`, `whisper`, `openai` | `voxtral` |
| `VOXFLOW_WHISPER_MODEL` | Whisper model name | `small` |
| `VOXFLOW_OFFLINE` | Disable network model downloads | `1` |

## Key Patterns

### Swift

- **`@MainActor` coordinator pattern**: `AppCoordinator` orchestrates audio capture and workflow routing; 5 extracted coordinators handle settings, onboarding, text insertion, benchmarking, and privacy consent via protocol-typed properties. Views observe `AppCoordinator.state` unchanged.
- **Privacy gate helper**: `processWithPrivacyGate` centralizes the `privateAPI` vs `localOnly` branch for all three workflow processors (`processDictation`, `processTranslation`, `processMeeting`)
- **Auto-insert mode**: `InsertBehavior` enum (`.alwaysReview`, `.autoInsertRaw/Light/Polish`) controls whether dictation skips the review step. Persisted via `SettingsCoordinator`.
- **App-context tone resolution**: `resolveEffectiveTone()` checks user overrides → `SettingsCoordinator.defaultAppTones` → global `toneStyle`, keyed by `FocusTargetSnapshot.bundleID`. Overrides persisted as JSON in UserDefaults.
- **Clipboard bridge**: After successful AX direct insert, text is also copied to clipboard for recoverability. Skipped when paste fallback already uses clipboard.
- **Session memory**: `SessionMemoryStore` ring buffer exposed via `AppState.recentDictations` with re-insert and copy actions in the "Recent" tab.
- **Keychain for secrets**: API keys stored via `KeychainService` (not UserDefaults)
- **CF type bridging**: Use `CFGetTypeID()` guard + `as!` for AXUIElement/AXValue casts (Swift 6.2 rejects `as?` on CF types)
- **os.Logger**: Use `Logger(subsystem: "local.voxflow.app", category: "...")` for logging
- **Accessibility API**: `AccessibilityInsertService` handles text insertion via AX direct write or simulated paste fallback; returns `(name, bundleID)` tuple from `focusedAppInfo`

### Python

- **ConsentStore**: Thread-safe token store with 30-min TTL; prune + resolve under single lock
- **Privacy redaction**: Regex-based PII redaction with preview before insertion
- **Rate limiting**: 120 requests per 60 seconds per IP
- **CORS**: Restricted to localhost origins only
- **Logging**: Use `logging.getLogger("voxflow")`, never bare `print()`

## Testing

- Test coverage: 201+ tests (110 Swift + 91 Python) covering models, parsing, coordinators, backend utilities
- Backend golden clip fixtures: `backend/tests/fixtures/golden_clips/`
- Run Swift tests: `swift test`
- Run backend tests: `cd backend && python -m pytest`

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Swift build fails with PCH path errors | Stale build cache after project move | `rm -rf .build` |
| `ModuleNotFoundError: No module named 'fastapi'` | Broken venv after project move | `rm -rf .venv && ./scripts/bootstrap_backend.sh` |
| `conditional downcast to CoreFoundation type` error | Swift 6.2 CF type bridging | Use `CFGetTypeID` guard + `as!` (not `as?`) |
| Backend unreachable | Backend not running or wrong port | Run `./scripts/run_backend.sh`, check port 8765 |

## Git

- Main branch: `main`
- Commit style: imperative mood, concise summary line, detailed body for multi-file changes
- Models directory (`models/`) is not tracked (too large)
- Never commit `.env`, API keys, or credential files

## Do Not

- Modify extracted coordinator protocols without updating both the coordinator and AppCoordinator forwarding methods
- Move workflow routing logic (`processDictation`, `processTranslation`, `processMeeting`) out of AppCoordinator — it belongs with the audio capture orchestration
- Bypass `resolveEffectiveTone()` — always use it instead of reading `state.toneStyle` directly in workflow processors
- Store app tone overrides as anything other than `[String: String]` JSON in UserDefaults (keyed by bundleID, values are `ToneStyle.rawValue`)
- Use `URLSession.shared` — use the configured session in `BackendAPIClient` (has timeouts)
- Store secrets in UserDefaults — use `KeychainService`
- Use bare `except Exception: pass` in Python — always log
- Hardcode absolute paths in scripts — use `BASH_SOURCE`-relative resolution
