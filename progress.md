# Phase 2 — Decompose & Test (Progress)

**Branch:** `feature/phase-2-decompose`
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 2
**Baseline:** 256 Swift + 282 Python = 538 tests, all green, clean build.

## Extraction order

Dependency-correct, bottom-up: **nlp → privacy → engines → routing → api**

The user's task list numbered engines first; I'm reordering to match the import dependency graph so each extraction leaves a clean intermediate state. End state is identical.

## Task tracker

### Python decomposition (server.py → 5 modules)

- [x] **Task 4 (renumbered to 1):** Extract `backend/app/nlp/` package ✅
  - [x] `nlp/cleanup.py` — normalize_whitespace, replace_spoken_punctuation, remove_repeated_words, remove_fillers, split_and_recase, light_cleanup
  - [x] `nlp/tone.py` — _apply_concise_tone, _apply_formal_tone, _apply_friendly_tone, apply_tone
  - [x] `nlp/hallucination.py` — _WHISPER_HALLUCINATION_*, is_whisper_hallucination
  - [x] `nlp/sentences.py` — split_sentences
  - [x] `nlp/meeting.py` — infer_speaker_segments, infer_task_owners, coerce_*, render_meeting_*_export, build_meeting_summary
  - server.py: 2274 → 1782 lines (492 lines moved into nlp/). All 282 Python tests + 256 Swift tests green.
- [ ] **Task 2 (renumbered to 2):** Extract `backend/app/privacy/` package
  - [ ] `privacy/consent.py` — ConsentRecord, ConsentStore, AuditLogger
  - [ ] `privacy/redaction.py` — redact_sensitive_text
- [ ] **Task 1 (renumbered to 3):** Extract `backend/app/engines/` package
  - [ ] `engines/whisper.py` — WhisperEngine, OpenAIAudioClient
  - [ ] `engines/polish.py` — PolishEngine
  - [ ] `engines/translate.py` — TranslateEngine
  - [ ] `engines/prompt_framing.py` — PromptFramingEngine
- [ ] **Task 3 (renumbered to 4):** Extract `backend/app/routing/` package
  - [ ] `routing/private_api.py` — PrivateAPIClient, PrivateAPIPolicy
  - [ ] `routing/provider.py` — ProviderRouter, ResolvedProviderInput
- [ ] **Task 5:** Extract `backend/app/api/` package
  - [ ] `api/routes.py` — FastAPI route handlers
  - [ ] `api/middleware.py` — rate limiting + CORS
  - [ ] `server.py` becomes composition root (~100 lines)

### Swift coordinator extraction

- [ ] **Task 6:** Extract `DictationWorkflowCoordinator` from `AppCoordinator.swift:1081-1206`
- [ ] **Task 7:** Add shared `autoInsertOrReview(_:mode:trace:)` helper
- [ ] **Task 8:** Collapse backend-readiness `@Published` properties into `BackendReadinessState` struct

### Concurrency hardening

- [ ] **Task 9:** Wrap ML inference in `run_in_executor` with `asyncio.Semaphore(2)`, 503 on saturation
- [ ] **Task 10:** Replace `PrivateAPIClient` urllib with `httpx.AsyncClient`
- [ ] **Task 11:** Align `GlobalHotkeyService` + `FnHoldHotkeyService` Carbon-callback pattern

### New tests

- [ ] **Task 12:** Unit tests for `FnHoldHotkeyService` debounce logic
- [ ] **Task 13:** Unit tests for `BackendProcessManager` auto-restart state machine
- [ ] **Task 14:** Replace `AppCoordinatorSmokeTests` with coordinator-driven tests

## Verification after every task

```bash
swift test 2>&1 | tail -5
./.venv/bin/python -m pytest backend/tests -v 2>&1 | tail -20
./.venv/bin/python -c "from backend.app.server import app; print('server imports clean')"
```

Acceptance: 538+ tests stay green; no behavior changes; no circular imports.
