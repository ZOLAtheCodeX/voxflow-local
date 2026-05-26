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
- [x] **Task 2:** Extract `backend/app/privacy/` package ✅
  - [x] `privacy/consent.py` — ConsentRecord, ConsentStore, AuditLogger
  - [x] `privacy/redaction.py` — redact_sensitive_text
  - server.py: 1782 → 1693 lines. 282 Python + 256 Swift tests still green.
- [x] **Task 1:** Extract `backend/app/engines/` package ✅
  - [x] `engines/whisper.py` — WhisperEngine, OpenAIAudioClient
  - [x] `engines/polish.py` — PolishEngine
  - [x] `engines/translate.py` — TranslateEngine
  - [x] `engines/prompt_framing.py` — PromptFramingEngine
  - Also moved: `engines/_utils.py` (resolve_model_ref, preferred_torch_device), `engines/results.py` (STTExecutionResult).
  - server.py: 1693 → 1054 lines (639 lines moved into engines/). 282 Python + 256 Swift tests still green.
- [x] **Task 3:** Extract `backend/app/routing/` package ✅
  - [x] `routing/private_api.py` — PrivateAPIClient, PrivateAPIPolicy
  - [x] `routing/provider.py` — ProviderRouter, ResolvedProviderInput
  - [x] `routing/utils.py` — normalize_provider_mode, normalize_stt_backend, extract_json_object, coerce_string_list, is_placeholder_text (helpers used by routing)
  - Also moved: `schemas.py` (all Pydantic Request/Response classes — required to break circular import between server and routing).
  - server.py: 1054 → 498 lines (556 more moved out). 282 Python + 256 Swift tests still green.
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
./.venv/bin/python -c "import sys; sys.path.insert(0, 'backend/app'); from server import app; print('server imports clean')"
```

Acceptance: 538+ tests stay green; no behavior changes; no circular imports.

## Ralph Loop Execution Protocol

This document is the source of truth for what is done and what is next.

Each iteration:

1. Read this file. Find the first task whose checkbox is `[ ]`.
2. Implement it. Strict rules from CLAUDE.md:
   - Zero behavior changes — pure structural refactor
   - Use `logging.getLogger("voxflow")` in new Python modules; never bare `print()`
   - In Swift, always use `resolveEffectiveProfile()` — never read `state.toneStyle` directly
   - Never move workflow routing logic out of `AppCoordinator` — keep forwarding methods
   - No circular imports
3. Verify before commit (all must pass):
   - `./.venv/bin/python -m pytest backend/tests -q` shows 282+ passed
   - `swift test` shows 256+ passed
   - `./.venv/bin/python -c "import sys; sys.path.insert(0, 'backend/app'); from server import app; print('ok')"` succeeds
4. Commit with an imperative message. Include the Co-Authored-By trailer used in prior commits.
5. Update this file: change `[ ]` to `[x]` for the completed task and add a one-line summary with line-count delta where relevant.
6. If any `[ ]` task remains, end the iteration without the completion promise. The loop will re-fire.
7. If all tasks are `[x]`:
   - Run the full suite: `./scripts/test_all.sh --skip-runtime-checks`. Must show all green.
   - Output the completion promise: `<promise>PHASE 2 COMPLETE</promise>`

If blocked on a task you cannot resolve, add a `## Blockers` section to this file with the blocker text and output `<promise>PHASE 2 BLOCKED: short reason</promise>`.

### Extraction notes (for the Python tasks)

- `engines/` should split into `engines/whisper.py` (WhisperEngine + OpenAIAudioClient), `engines/polish.py` (PolishEngine), `engines/translate.py` (TranslateEngine), `engines/prompt_framing.py` (PromptFramingEngine).
- `routing/` should split into `routing/private_api.py` (PrivateAPIClient + PrivateAPIPolicy) and `routing/provider.py` (ProviderRouter + ResolvedProviderInput).
- `api/` should split into `api/middleware.py` (rate limiting + CORS) and `api/routes.py` (FastAPI handlers). After this, `server.py` is the composition root: roughly 100 lines that create the app, register middleware, mount routes, and define `initialize_runtime_state`.
- Keep the `from nlp import ...` and `from privacy import ...` patterns; `server.py` re-exports the public names so existing `from server import X` paths in tests continue to work without test changes.

### Swift notes (for tasks 6, 7, 8, 11, 12, 13, 14)

- `DictationWorkflowCoordinator` should mirror `TranslationWorkflowCoordinator.swift` shape: protocol-typed, owns its workflow, and has a forwarding pair on `AppCoordinator` (start + finish).
- `autoInsertOrReview(_:mode:trace:)` lives on `AppCoordinator` (or on the new `DictationWorkflowCoordinator` once extracted) and replaces the two near-identical auto-insert blocks in `processDictation`.
- `BackendReadinessState` is a value-type struct exposed as a single `@Published var backendReadiness: BackendReadinessState` on `AppState`. It absorbs `backendReadyForDictation`, `backendWarmupInProgress`, `backendStatusSummary`, `backendActiveSTTModel`, and the other readiness-cluster properties currently scattered as separate `@Published` properties.
- Concurrency task 11: both hotkey services should use the same Carbon-callback pattern. Pick the pattern that wraps in `Task { @MainActor }` internally so callers do not need to. Document the invariant in a comment at the top of each file.
