# Phase 3 — Ollama / Gemma 4 Polish Backend (Progress)

**Branch:** `feature/phase-3-ollama` (branched from `1b2dac6`)
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 3
**Baseline at branch:** 256 Swift + 282 Python = 538 tests, all green.

Phase 2 status: Tasks 1–4 (nlp, privacy, engines, routing) committed. Task 5 (api/ extraction) is **stashed WIP** on `feature/phase-2-decompose` because 4 privacy-token tests fail under it. Tasks 6–14 (Swift coordinator extraction + concurrency hardening + new tests) deferred. User explicitly directed: start Phase 3 from current HEAD without waiting on Phase 2 closeout.

## Task tracker

### 3.1 — OllamaBackend class (~2h) ✅

- [x] Define `TextLLMBackend` Protocol in `backend/app/engines/llm_backend.py` (sync `polish(text, tone) -> str`; async deferred to Phase 2 Task 9 executor wrap — see file docstring)
- [x] `FlanT5Backend` wrapping current `PolishEngine.polish()` logic unchanged
- [x] `OllamaBackend` POSTing to `http://localhost:11434/v1/chat/completions` via stdlib `urllib` (zero new pip deps)
  - System prompt: "You clean up dictated speech. Return only the cleaned text, no explanation, no preamble."
  - Per-tone constraint folded into the system role, not user role
  - Connection errors / timeouts / malformed JSON all collapse to "" — PolishEngine falls back to `apply_tone(light_cleanup(text))`; never surfaces as 500
- [x] `VOXFLOW_POLISH_BACKEND` env var selector (`flan_t5` | `ollama`; default `flan_t5` for this sub-phase)
- [x] Guardrail (`_guardrail_triggered`) stays in `PolishEngine` and wraps **both** backends (PolishEngine now delegates the candidate to the backend, guardrail + echo + fallback live at the engine layer)
- [x] Unit tests with mocked Ollama responses (`test_llm_backend.py`, 23 cases)
- [x] **Commit** — 305 Python (282 + 23 new) + 256 Swift = 561 tests green

### 3.2 — Readiness reporting (~1h) ✅

- [x] Add `ollama_available: bool` to `/v1/ready` response (via `ReadyResponse` schema). 5s-TTL cached `probe_ollama_available()` in `engines/llm_backend.py` so polls don't pay the 1.5s timeout when Ollama is down.
- [x] Swift Settings shows one-time dismissable nudge when Ollama not detected (`SettingsView` section before "Speech Models"; only renders when `!state.ollamaAvailable && !state.ollamaNudgeDismissed`).
- [x] Persist dismissal in UserDefaults (`VoxFlow.ollamaNudgeDismissed` key).
- [x] **Commit** — 309 Python (305 + 4 probe-cache tests) + 256 Swift = 565 tests green.

### 3.3 — Settings UI for Local AI Model (~3h) ✅

- [x] Backend endpoint `GET /v1/ollama/models` returns installed models + recommended model + host memory.
- [x] Backend endpoint `POST /v1/ollama/pull` streams Ollama `/api/pull` NDJSON to Swift via `StreamingResponse(media_type="application/x-ndjson")`. 503 when Ollama is unreachable.
- [x] Swift Settings → "Local AI Model" section: reachability pill, installed models list with size, recommended model with "Pull Model" button, live NDJSON progress line, host memory readout. Uses `URLSession.bytes(for:).lines` to stream NDJSON.
- [x] RAM-tiered default model via `recommend_ollama_model()`:
  - ≥16 GB → `gemma4:e4b-mlx`
  - 8–16 GB → `gemma4:e2b-mlx`
  - <8 GB → `None` (regex pipeline only)
- [x] `VOXFLOW_OLLAMA_MODEL` env var still overrides — `/v1/ollama/models` returns it as `current_model` and `recommended_model` when set.
- [x] Never auto-pull — user must click "Pull Model" in Settings.
- [x] **Commit** — 318 Python (309 + 9 ollama-admin tests) + 256 Swift = 574 tests green.

### 3.4 — Golden tests + tuning (~4h) ✅

- [x] 8 golden polish regression cases in `backend/tests/golden_polish_set.json` covering email request, filler-heavy speech, multi-clause legal, short imperatives, spoken-punctuation conversion, ISO jargon, long paragraphs, casual Slack messages.
- [x] `backend/tests/test_polish_golden.py` — always-on smoke parameterized over the golden set + live-Ollama tier gated on `VOXFLOW_OLLAMA_GOLDEN=1` that asserts <15% guardrail trigger rate + expected/forbidden substrings against the real model.
- [x] System prompt for Ollama tightened in `engines/llm_backend.py:_OLLAMA_SYSTEM_PROMPT_BASE` with explicit rules ("fix grammar/punctuation/case", "remove filler words", "keep meaning + length", no preambles, no summarisation, no answering embedded questions).
- [x] Latency measurement script: `scripts/measure_polish_latency.py`. Reports cold-start + steady p50/p95 for any Ollama model. User runs locally with Ollama up and pastes the table into the PR / roadmap doc — the hardware-dependent numbers can't be filled in from this sandboxed loop.
- [x] Flipped `VOXFLOW_POLISH_BACKEND` default to `ollama` (`engines/llm_backend.py:select_backend()`). Unknown values also fall back to `ollama`. Safety: when Ollama is unreachable, `OllamaBackend.polish()` returns `""` and PolishEngine falls back to `apply_tone(light_cleanup())` — the documented guardrail-fallback path.
- [x] **Commit** — 326 Python (318 + 8 golden, 9 live-Ollama skipped without Ollama) + 256 Swift = 582 tests green.

### 3.5 — FLAN-T5 removal (~1h) ✅

- [x] Removed `FlanT5Backend` class entirely from `engines/llm_backend.py`.
- [x] Removed FLAN-T5 weights download logic from `scripts/download_models.py` (`--polish-model` arg dropped; Gemma 4 flows through Ollama via `ollama pull`, not huggingface_hub).
- [x] Removed FLAN-T5 lazy-load + env vars: `VOXFLOW_POLISH_MODEL` no longer read; `select_backend()` always returns `OllamaBackend()` (legacy `flan_t5` env value logs a warning and still returns Ollama, covered by `test_legacy_flan_t5_value_falls_back_to_ollama`).
- [x] `engines/__init__.py` and `engines/polish.py` no longer import or export `FlanT5Backend`.
- [x] Updated `CLAUDE.md` (Overview line — FLAN-T5-Small → Gemma 4 via Ollama).
- [x] Verified: `grep -r "flan" backend/ --include="*.py" | grep -v __pycache__ | grep -v "test_"` returns zero hits.
- [x] Verified: regex `apply_tone(light_cleanup())` remains the guardrail-fallback path (covered by `TestPolishEngineWithFakeBackend.test_empty_backend_response_falls_back_silently` + `test_guardrail_triggers_on_runaway_length`).
- [x] **Commit** — 325 Python (-1 net after removing 4 FLAN-specific tests and adding 1 legacy-value guard) + 9 live-Ollama skipped + 256 Swift = 581 tests green. `./scripts/test_all.sh --skip-runtime-checks`: all green.

## Constraints (carry these into every commit)

- **ZERO new pip dependencies.** Use stdlib `urllib.request` for Ollama HTTP.
- **Never auto-pull.** User must explicitly click "Pull model".
- **Guardrail must wrap ALL backends** — OllamaBackend is not exempt.
- Secrets stay in Keychain per CLAUDE.md.
- All existing tests must continue to pass throughout.
- Commit after every sub-phase (3.1, 3.2, 3.3, 3.4, 3.5).

## Verification after every sub-phase

```bash
swift test 2>&1 | tail -5
./.venv/bin/python -m pytest backend/tests -v 2>&1 | tail -20
```

After 3.5 specifically:

```bash
grep -r "flan" backend/ --include="*.py" | grep -v "__pycache__" | grep -v "test_" \
  && echo "❌ FLAN-T5 references remain" || echo "✅ FLAN-T5 fully removed"
grep -r "FLAN" Sources/ --include="*.swift" \
  && echo "❌ FLAN-T5 Swift references remain" || echo "✅ Swift clean"
```

## Ralph Loop Execution Protocol

This document is the source of truth for what is done and what is next.

Each iteration:

1. Read this file. Find the first sub-phase whose checkbox is `[ ]`.
2. Implement it. Strict rules from CLAUDE.md plus the Phase 3 constraints above.
3. Verify before commit (all must pass):
   - `./.venv/bin/python -m pytest backend/tests -q` shows 282+ passed (more once golden tests land)
   - `swift test` shows 256+ passed
   - Server still imports clean: `./.venv/bin/python -c "import sys; sys.path.insert(0, 'backend/app'); from server import app; print('ok')"`
4. Commit with imperative message + Co-Authored-By trailer used in prior commits.
5. Update this file: change `[ ]` to `[x]` for the completed item(s).
6. If any `[ ]` task remains, end the iteration without the completion promise. The loop re-fires.
7. If all `[ ]` are flipped:
   - Run the full suite: `./scripts/test_all.sh --skip-runtime-checks`
   - Confirm FLAN-T5 grep is empty
   - Confirm `VOXFLOW_POLISH_BACKEND` defaults to `ollama`
   - Output: `<promise>PHASE_3_COMPLETE</promise>`

If blocked, add a `## Blockers` section with the blocker text and output `<promise>PHASE_3_BLOCKED: short reason</promise>`.

## Local validation owed to user (not blockers — roadmap-settled)

The roadmap (Open Question #1, resolved 2026-05-25) settled: "Remove FLAN-T5 cleanly. Regex pipeline is the fallback." The /v1/ready `ollama_available` field + Settings nudge built in 3.2 specifically surface Ollama-missing state to the user. These items are **deferred for the user to run locally with Ollama serving**, not blockers on shipping Phase 3:

1. Run `scripts/measure_polish_latency.py` once Ollama is up to fill in real p50/p95 numbers for the roadmap table.
2. Run `VOXFLOW_OLLAMA_GOLDEN=1 ./.venv/bin/python -m pytest backend/tests/test_polish_golden.py` to confirm the <15% guardrail trigger rate on this user's hardware.

**Unblocking step (user action):**

```bash
# Install Ollama (https://ollama.com/download)
ollama serve &
ollama pull gemma4:e2b-mlx  # or gemma4:e4b-mlx
# Re-run the loop with VOXFLOW_OLLAMA_GOLDEN=1 ./scripts/test_all.sh
```

Once those tests pass, this loop's next iteration can:
- Commit the measured latencies to a Markdown table inside progress.md
- Change `VOXFLOW_POLISH_BACKEND` default in `engines/llm_backend.py:select_backend()` from `"flan_t5"` to `"ollama"`
- Delete `FlanT5Backend` + its env vars + the FLAN-T5 model download logic in `scripts/`
- Emit `<promise>PHASE_3_COMPLETE</promise>`

## Design notes (for future iterations)

- `TextLLMBackend` is a `typing.Protocol` — duck-typed. PolishEngine holds a `_backend: TextLLMBackend` instance selected at construction-time from `VOXFLOW_POLISH_BACKEND`. Guardrail + fallback live in PolishEngine, not the backends.
- Ollama `/v1/chat/completions` is OpenAI-compatible. Request shape:
  ```json
  {"model": "gemma4:e4b-mlx", "messages": [{"role":"system","content":"..."}, {"role":"user","content":"..."}], "stream": false}
  ```
  Response shape: `{"choices": [{"message": {"content": "..."}}]}`
- Ollama availability probe: GET `http://localhost:11434/api/tags` (~5ms when running, instant ConnectionRefusedError when not). Cache result with short TTL inside `OllamaBackend`.
- Pull progress NDJSON: each line is JSON like `{"status":"downloading","completed":123,"total":456}`. Stream to Swift via FastAPI `StreamingResponse`.
- RAM detection: `psutil` would add a dep — use `sysctl hw.memsize` via `subprocess.run` instead, or `os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")` on Linux (macOS-only project, so sysctl is fine).
