# VoxFlow Local — Project Conventions

## Overview

VoxFlow Local is a macOS-native dictation app: SwiftUI menu bar frontend + Python FastAPI backend with on-device ML inference (Voxtral-Mini-3B, Whisper-Small, FLAN-T5-Small).

## Architecture

```
Sources/VoxFlowApp/        Swift frontend (SwiftUI, MenuBarExtra)
  AppCoordinator.swift      Central orchestrator (~580 lines, @MainActor)
  Services/                 Extracted coordinators + backend services
    SettingsCoordinator.swift           Provider, STT, insert behavior, app tone overrides + persistence
    OnboardingCoordinator.swift         Calibration flow lifecycle
    TextInsertionCoordinator.swift      AX insert, clipboard copy/bridge, per-app stats
    TranslationBenchmarkCoordinator.swift  Profile benchmarking + history
    PrivacyConsentCoordinator.swift     Privacy preview + closure-based continuation
    AccessibilityInsertService.swift    AX text insertion + bundleID-aware app info
    SessionMemoryStore.swift            Ring buffer for recent dictations (recent/push/count)
    MenuBarPanelController.swift        Non-activating NSPanel + NSStatusItem for menu bar palette
  Models/AppModels.swift    All domain types (enums, structs, InsertBehavior, FocusTargetSnapshot)
  State/AppState.swift      Published app state (~50 @Published properties)
  Views/                    SwiftUI views
backend/app/
  server.py                 FastAPI server (~1700 lines, all endpoints)
scripts/                    Shell scripts (bootstrap, test, run, doctor, launcher, release)
models/                     Pre-downloaded ML models (~24GB, not in git)
  whisperkit-coreml__openai_whisper-small.en/  Pre-downloaded WhisperKit CoreML model
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
- Health check: `curl http://127.0.0.1:8765/v1/health`
- Readiness contract: `curl http://127.0.0.1:8765/v1/ready`

### Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `VOXFLOW_MODELS_DIR` | Path to pre-downloaded models | `./models` |
| `VOXFLOW_BACKEND_URL` | Backend URL override (Swift) | `http://127.0.0.1:8765` |
| `VOXFLOW_BACKEND_PATH` | Backend server.py path override | auto-resolved |
| `VOXFLOW_PYTHON_PATH` | Python executable override | auto-resolved |
| `VOXFLOW_PROJECT_ROOT` | Project root override | auto-resolved |
| `VOXFLOW_STT_BACKEND` | STT engine: `voxtral`, `whisper`, `whisperKit`, `openai` | `voxtral` |
| `VOXFLOW_WHISPER_MODEL` | Whisper model name | `small` |
| `VOXFLOW_OFFLINE` | Disable network model downloads | `1` |

## Key Patterns

### Swift

- **`@MainActor` coordinator pattern**: `AppCoordinator` orchestrates audio capture and workflow routing; 5 extracted coordinators handle settings, onboarding, text insertion, benchmarking, and privacy consent via protocol-typed properties. Views observe `AppCoordinator.state` unchanged.
- **Privacy gate helper**: `processWithPrivacyGate` centralizes the `privateAPI` vs `localOnly` branch for all three workflow processors (`processDictation`, `processTranslation`, `processMeeting`)
- **Auto-insert mode**: `InsertBehavior` enum (`.alwaysReview`, `.autoInsertRaw/Light/Polish`) controls whether dictation skips the review step. Persisted via `SettingsCoordinator`.
- **Feature gates**: Dictation core remains always-on; translation and meeting workflows are experimental toggles (`translationModeEnabled`, `meetingModeEnabled`) surfaced through Settings and workflow picker filtering.
- **Per-app profile resolution**: `resolveEffectiveProfile()` checks `state.appProfiles[bundleID]` → `SettingsCoordinator.defaultAppProfiles[bundleID]` → `nil` (callers fall back to global settings). Profiles include tone, cleanup mode, and insert behavior. Persisted as JSON `[String: AppProfile]` in UserDefaults.
- **Clipboard bridge**: After successful AX direct insert, text is also copied to clipboard for recoverability. Skipped when paste fallback already uses clipboard.
- **Session memory**: `SessionMemoryStore` ring buffer exposed via `AppState.recentDictations` with re-insert and copy actions in the "Recent" tab.
- **Keychain for secrets**: API keys stored via `KeychainService` (not UserDefaults)
- **CF type bridging**: Use `CFGetTypeID()` guard + `as!` for AXUIElement/AXValue casts (Swift 6.2 rejects `as?` on CF types)
- **os.Logger**: Use `Logger(subsystem: "local.voxflow.app", category: "...")` for logging
- **Accessibility API**: `AccessibilityInsertService` handles text insertion via AX direct write or simulated paste fallback; returns `(name, bundleID)` tuple from `focusedAppInfo`
- **Non-activating panel**: Menu bar palette uses `NSPanel` with `.nonactivatingPanel` style mask and `.floating` level via `MenuBarPanelController`. Never steals focus from the target app.
- **Target snapshot**: `capturedTargetApp` is frozen at `startCapture()` time and threaded through the pipeline to `insert(text:targetApp:)`. `FocusContextMonitor` freezes during active sessions via `freeze()`/`unfreeze()`.
- **Dynamic activation policy**: `activateForWindow()` toggles between `.regular` (Dock visible) and `.accessory` (menu-bar-only) based on whether managed windows are open. `LSUIElement = true` in Info.plist.
- **WhisperKit native STT**: `WhisperKitSTTService` wraps WhisperKit library for in-process CoreML/ANE transcription. Loaded from `models/whisperkit-coreml__openai_whisper-small.en/` with `download: false` (zero network). Selected via `STTBackend.whisperKit` in Settings. Falls through to same `TranscribeResponse` type as backend STT path.
- **TextCleanupService**: Swift-native 7-step NLP-lite cleanup pipeline using Apple NaturalLanguage framework (NLTokenizer, NLTagger). Handles spoken punctuation, filler removal (POS-aware), repeated word dedup, sentence splitting, recasing, and tone transforms. Used in-process when `sttBackend == .whisperKit` — no Python backend needed for cleanup.

### Python

- **ConsentStore**: Thread-safe token store with 30-min TTL; prune + resolve under single lock
- **Privacy redaction**: Regex-based PII redaction with preview before insertion
- **Rate limiting**: 120 requests per 60 seconds per IP
- **CORS**: Restricted to localhost origins only
- **STT chunking**: Both VoxtralEngine and WhisperEngine use `chunk_length_s=30` with `stride_length_s=[5, 1]` for long-form transcription (30-45s)
- **Logging**: Use `logging.getLogger("voxflow")`, never bare `print()`

## Testing

- Test coverage: 253+ tests (143 Swift + 110 Python) covering models, parsing, coordinators, backend utilities
- Backend golden clip fixtures: `backend/tests/fixtures/golden_clips/`
- Run Swift tests: `swift test`
- Run backend tests (venv): `./.venv/bin/python -m pytest backend/tests`
- Run full suite: `./scripts/test_all.sh`

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Swift build fails with PCH path errors | Stale build cache after project move | `rm -rf .build` |
| `ModuleNotFoundError: No module named 'fastapi'` | Broken venv after project move | `rm -rf .venv && ./scripts/bootstrap_backend.sh` |
| `conditional downcast to CoreFoundation type` error | Swift 6.2 CF type bridging | Use `CFGetTypeID` guard + `as!` (not `as?`) |
| Backend unreachable | Backend not running or wrong port | Run `./scripts/run_backend.sh`, check port 8765 |

## Git

- Primary branch: `master`
- Commit style: imperative mood, concise summary line, detailed body for multi-file changes
- Models directory (`models/`) is not tracked (too large)
- Never commit `.env`, API keys, or credential files

## Do Not

- Modify extracted coordinator protocols without updating both the coordinator and AppCoordinator forwarding methods
- Move workflow routing logic (`processDictation`, `processTranslation`, `processMeeting`) out of AppCoordinator — it belongs with the audio capture orchestration
- Bypass `resolveEffectiveProfile()` — always use it instead of reading `state.toneStyle` directly in workflow processors
- Store app profiles as anything other than `[String: AppProfile]` JSON in UserDefaults (keyed by bundleID)
- Use `URLSession.shared` — use the configured session in `BackendAPIClient` (has timeouts)
- Store secrets in UserDefaults — use `KeychainService`
- Use bare `except Exception: pass` in Python — always log
- Hardcode absolute paths in scripts — use `BASH_SOURCE`-relative resolution
- Call `NSApp.activate(ignoringOtherApps: true)` directly — use `activateForWindow()` which manages the activation policy toggle
- Read `NSWorkspace.shared.frontmostApplication` at insert time — use the frozen `capturedTargetApp` from `startCapture()`
- Use `WhisperKit()` default init (it phones home to HuggingFace) — always use `WhisperKitConfig(modelFolder:, download: false)`
