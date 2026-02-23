# VoxFlow Local

Mac-native, local-only dictation app with WhisperKit/Whisper STT, post-capture cleanup (`Raw`, `Light`, `Polish`), and experimental EN->DE translate, meeting notes, and prompt framing modes.

## Implemented

- Main app window (Dashboard/Settings/Setup tabs) plus menu bar command palette (`SwiftUI` + `AppKit` bridge)
- Global hold-to-talk hotkey (default `Fn` hold/release, configurable in Settings)
- System command lane hotkey (default `Fn + Command + Space`, configurable in Settings) with alternate UI color state
- Keyboard-first palette shortcuts (`Cmd+1` setup, `Cmd+2` dashboard, `Cmd+,` settings, `Cmd+Q` quit, `Esc` cancel capture/review)
- Onboarding calibration flow (first run phrase capture)
- Target-aware activation (focused text field / active cursor)
- Cleanup mode chips (`Raw`, `Light`, `Polish`)
- Tone/style controls (`Neutral`, `Concise`, `Formal`, `Friendly`)
- Per-app profiles (tone + cleanup mode + insert behavior per target app bundleID)
- Accessibility insertion with paste fallback
- Session-only in-memory history
- Local backend API (`FastAPI`) with:
  - `POST /v1/transcribe`
  - `POST /v1/tts`
  - `POST /v1/cleanup`
  - `POST /v1/translate` (EN->DE)
  - `POST /v1/meeting_summarize`
  - `POST /v1/prompt/frame`
  - `POST /v1/privacy/preview`
  - `WS /v1/events`
  - `GET /v1/health`
  - `GET /v1/ready`
- Experimental Translate Mode UX:
  - Captured English in a raised card
  - German output card
  - Required approve button before insertion
  - Settings selector for translation profile:
    - `TranslateGemma 4B`
    - `TranslateGemma 12B`
    - `Marian Fallback`
  - RAM-aware latency/VRAM suitability badges for each profile
  - In-app translation benchmark mode with median and p95 latency per profile
- Meeting Mode UX:
  - Structured notes generation from captured transcript
  - Sections: summary, decisions, action items, follow-ups
  - Speaker segmentation (heuristic, local)
  - Task-owner extraction with confidence estimates
  - One-click export templates (Markdown + Notion-style)
  - Required approval before insertion
- Dashboard landing panel in command palette:
  - Session captures (local/API split), latency averages, insert success, approval counts
  - Mode usage summary (Dictation/Translate/Meeting capture distribution)
  - Recommended translation profile card from benchmark history
  - Quick actions: switch to capture panel, reset session metrics
- Dedicated dashboard window:
  - Open from menu bar (`Open Dashboard`)
  - Session telemetry cards + per-app compatibility matrix
  - Benchmark recommendation section with profile history table
  - Tracks insert success/fallback/failure by application
- WhisperKit native STT — CoreML/Apple Neural Engine, in-process inference, zero network
- Configurable STT backend:
  - `WhisperKit (Local, Neural Engine)` — default, fastest
  - `Whisper (Local, open-source)`
  - `OpenAI STT`
- OpenAI speech configuration:
  - STT model + TTS model + voice can be set in Settings
- Provider mode picker:
  - `Local Models` (default, local/offline)
  - `Private API` (OpenAI-compatible external endpoint)
- Privacy gateway for private API mode:
  - Compare original vs redacted transcript before sending
  - Explicit approve action (`Approve Redacted` or `Approve Raw`)
  - Consent token required on backend for API execution
  - Metadata-only audit logging (no transcript content in logs)

## Repo Layout

- `Sources/VoxFlowApp`: macOS app
- `backend/app/server.py`: local inference service
- `scripts/bootstrap_backend.sh`: create venv + install backend deps
- `scripts/bootstrap_all.sh`: bootstrap backend deps and run initial Swift build
- `scripts/run_backend.sh`: run backend server
- `scripts/test_all.sh`: run Swift tests + backend tests via `.venv`
- `scripts/download_models.py`: optional model pre-download
- `scripts/launch_voxflow.sh`: one-command launcher (backend + app)
- `scripts/stop_voxflow.sh`: stop app and backend
- `scripts/build_app_bundle.sh`: build a native `.app` bundle with icon (`dist/VoxFlow.app`)
- `scripts/install_app_bundle.sh`: install bundle into `~/Applications` with validation + LaunchServices registration
- `scripts/open_app_bundle.sh`: open bundled app (builds first if missing, falls back to direct binary launch)
- `scripts/reinstall_and_launch.sh`: build + install + launch in one command (auto-fallback to direct executable launch)
- `scripts/check_runtime_readiness.sh`: verifies backend health + whether active STT model is loaded
- `scripts/release_signed.sh`: release contract for signed + notarized direct app artifacts
- `scripts/prepare_models_and_run_regression.sh`: downloads required STT models and runs regressions (`whisper`)
- `scripts/create_desktop_launcher.sh`: creates a Desktop launcher (`VoxFlow.command`)
- `scripts/doctor.sh`: checks installed app bundle, executable, models dir, and backend health
- `scripts/run_regression_suite.sh`: deterministic STT/cleanup regression + latency report
- `backend/tests/regression_manifest.json`: golden clip + cleanup invariants spec

## Local Setup

Run commands from the repository root (`voxflow-local/`).

1. Bootstrap everything:

```bash
./scripts/bootstrap_all.sh
```

2. (Optional but recommended) pre-download models:

```bash
./scripts/download_models.py --cache-dir ./models
```

3. Run backend:

```bash
./scripts/run_backend.sh
```

4. Run app:

```bash
swift run VoxFlowLocal
```

Optional native app bundle (Finder/Dock launch):

```bash
./scripts/build_app_bundle.sh
./scripts/install_app_bundle.sh
open ~/Applications/VoxFlow.app
```

One-command repair + launch (recommended if bundle got corrupted/nested):

```bash
./scripts/reinstall_and_launch.sh --skip-build
```

Create a one-click Desktop launcher:

```bash
./scripts/create_desktop_launcher.sh
```

Run install/runtime diagnostics:

```bash
./scripts/doctor.sh
```

Bundle runtime note:
- `build_app_bundle.sh` now copies `.venv` into the app bundle by default (safer for macOS LaunchServices).
- VoxFlow runs as a menu-bar agent app by default (`LSUIElement = true`). The Dock icon appears only when a window (Dashboard, Setup, Settings) is open and disappears when all windows close.
- Use `--link-venv` only for faster local dev iteration.
- Use `FORCE_DOCK_ICON=1 ./scripts/build_app_bundle.sh` if you want a persistent Dock icon.

```bash
./scripts/build_app_bundle.sh --link-venv
```

To build an optimized release bundle:

```bash
./scripts/build_app_bundle.sh --release
```

Signed + notarized release artifact contract:

```bash
./scripts/release_signed.sh \
  --version 0.2.0 \
  --identity "Developer ID Application: Your Name (TEAMID1234)" \
  --team-id TEAMID1234 \
  --notary-profile voxflow-notary
```

If `open dist/VoxFlow.app` fails in your terminal environment, use:

```bash
./scripts/open_app_bundle.sh
```

This launcher automatically falls back to direct binary start and writes logs to:

```bash
./.runtime/app-direct.log
```

Or launch both backend + app in one command:

```bash
./scripts/launch_voxflow.sh
```

5. Run tests:

```bash
./scripts/test_all.sh
```

`test_all.sh` now runs runtime readiness + regression checks by default. Use `--skip-runtime-checks` for quick local iteration:

```bash
./scripts/test_all.sh --skip-runtime-checks
```

6. Run deterministic STT/cleanup regression suite:

```bash
./scripts/run_regression_suite.sh
```

Optional readiness preflight (recommended before regressions):

```bash
./scripts/check_runtime_readiness.sh
```

One-command model prep + regression (recommended for first pass):

```bash
./scripts/prepare_models_and_run_regression.sh
```

Outputs:
- Golden clips in `backend/tests/fixtures/golden_clips/*.wav`
- Latency percentile report in `backend/tests/reports/stt_latency_report.json`
- Per-backend latency tracking for `whisper`, `openai` (OpenAI is skipped if not configured)
- STT checks fail fast if a backend returns placeholder text (`[transcription unavailable ...]`), which indicates the model/runtime is not ready.

## Runtime Notes

- The backend is configured for offline runtime (`TRANSFORMERS_OFFLINE=1`, `HF_HUB_OFFLINE=1`) for local model mode.
- If local model files are available, set:

```bash
export VOXFLOW_MODELS_DIR="$(pwd)/models"
```

- Default model refs:
  - STT (WhisperKit): `openai/whisper-small` (CoreML, in-process via Apple Neural Engine)
  - STT (Whisper): `openai/whisper-small` (Python backend)
  - Polish: `google/flan-t5-small`
  - Translate: `google/translategemma-4b-it`

- Translate backend options:
  - `VOXFLOW_TRANSLATE_BACKEND=auto` (default; uses `translategemma` for TranslateGemma models, otherwise `marian`)
  - `VOXFLOW_TRANSLATE_BACKEND=translategemma`
  - `VOXFLOW_TRANSLATE_BACKEND=marian`

- Lower-memory fallback for translation:

```bash
export VOXFLOW_TRANSLATE_BACKEND=marian
export VOXFLOW_TRANSLATE_MODEL=Helsinki-NLP/opus-mt-en-de
```

- Note:
  - TranslateGemma models are access-controlled; make sure you have accepted model terms on Hugging Face before downloading.

- Optional private API adapter settings:

```bash
export VOXFLOW_PRIVATE_API_BASE_URL=https://your-endpoint.example.com
export VOXFLOW_PRIVATE_API_MODEL=your-model-id
export VOXFLOW_PRIVATE_API_KEY=your-api-key
```

- Privacy policy guardrail flags (required for private API mode; backend fails closed if missing):

```bash
export VOXFLOW_PRIVACY_POLICY_VERSION=2026-02
export VOXFLOW_PRIVACY_REQUIRE_CONSENT=1
export VOXFLOW_PRIVACY_RAW_CONFIRMATION_REQUIRED=1
```

- Private API mode uses `POST /v1/chat/completions` compatibility and requires per-request privacy preview approval.
- If private API mode is enabled, selected transcript content may leave your machine.

- Optional OpenAI speech settings:

```bash
export VOXFLOW_OPENAI_BASE_URL=https://api.openai.com
export VOXFLOW_OPENAI_API_KEY=your-openai-key
export VOXFLOW_OPENAI_STT_MODEL=whisper-1
export VOXFLOW_OPENAI_TTS_MODEL=gpt-4o-mini-tts
export VOXFLOW_OPENAI_TTS_VOICE=alloy
```

## Current Constraints

- If models are missing or fail to load, backend returns explicit placeholder text instead of crashing.
- Translate Mode is intentionally behind an experimental toggle in settings.
- Extended dictation supports 30-45 seconds of continuous speech (chunked transcription with sliding window).
- v1 targets microphone dictation only (no system audio/file transcription).
- WhisperKit is the default STT backend (fastest, zero network). Switch in Settings if needed.

## Backlog (Deferred)

- Launch at login (`SMAppService`) + settings toggle is intentionally deferred for now.
