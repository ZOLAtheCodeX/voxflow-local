# Contributing to VoxFlow Local

Thanks for considering a contribution. This is a macOS-native app with a
Swift frontend and a Python backend; both halves have full test suites and
the bar for merging is that everything stays green.

## Dev setup

Requirements: macOS 14+, Xcode with Swift 6.2, Python 3.11+.

```bash
# Backend (first time)
./scripts/bootstrap_backend.sh        # creates ./.venv and installs deps
./scripts/run_backend.sh              # uvicorn on 127.0.0.1:8765

# Frontend
swift build && swift run VoxFlowLocal # dev run (see note below)

# Optional: local LLM polish
ollama serve &
ollama pull gemma4:e2b-mlx            # 8-24 GB RAM; e4b-mlx only for >=24 GB
```

For anything involving Accessibility (text insertion), run the installed
bundle instead of the raw binary so macOS TCC sees a stable identity:
`./scripts/reinstall_and_launch.sh` builds, signs, installs to
`~/Applications/VoxFlow.app`, and relaunches.

`./scripts/doctor.sh` diagnoses the common environment problems.

## Tests

```bash
swift test                                   # Swift suite (fast, no system access)
./.venv/bin/python -m pytest backend/tests   # Python suite
./scripts/test_all.sh                        # everything incl. STT regression clips
./scripts/test_all.sh --skip-runtime-checks  # skip the model-dependent checks
```

Model-dependent tests skip automatically when the models or a live Ollama
are absent, so a plain checkout runs green without the ~24 GB model cache.

### Test rules that are enforced, not stylistic

- **Tests never touch the real system.** No test may construct a service
  that can insert text, spawn processes, signal PIDs, or bind ports. Use
  the seams: `TextInserting` for insertion, `BackendProcessRunning` (with
  `BackendProcessRunnerFake`) for the backend process lifecycle. History:
  a test once performed real accessibility insertions into whatever app
  had focus, and another planted orphaned uvicorn processes on port 8765
  on every suite run. Both classes are structurally sealed; do not reopen
  them.
- **Paired implementations stay in sync.** The Swift and Python
  hallucination filters share `Tests/Fixtures/hallucination_parity.json`;
  `providers.json` has a schema contract test between
  `ProviderConfigStore.swift` (writer) and `provider_registry.py` (reader).
  Change one side and the parity tests will tell you about the other.

## Conventions

- Swift: `@MainActor` coordinator pattern; design tokens through
  `VFDesignTokens.swift` (no raw `.font(.system(size:))` or ad-hoc colors in
  `Views/`); secrets in the Keychain, never UserDefaults; no
  `URLSession.shared` (use `BackendAPIClient`'s configured session).
- Python: log via `logging.getLogger("voxflow")`, never bare `print()`; no
  silent `except Exception: pass`.
- Commits: imperative subject, detailed body explaining the why. Branches:
  `feature/<topic>`.
- `CLAUDE.md` holds the full architecture map and the project's hard-won
  "do not" list; read it before touching the capture/insertion paths.

## Pull requests

Keep PRs focused. Include tests for behavior changes (the project is
test-driven: failing test first, then the fix). CI runs both suites on a
macOS runner; it must be green before review.
