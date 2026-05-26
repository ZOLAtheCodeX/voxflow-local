# Phase 3 — Ollama / Gemma 4 Polish Backend (Progress)

**Branch:** `feature/phase-3-ollama` (branched from `1b2dac6`)
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 3
**Baseline at branch:** 256 Swift + 282 Python = 538 tests, all green.

Phase 2 status: Tasks 1–4 (nlp, privacy, engines, routing) committed. Task 5 (api/ extraction) is **stashed WIP** on `feature/phase-2-decompose` because 4 privacy-token tests fail under it. Tasks 6–14 (Swift coordinator extraction + concurrency hardening + new tests) deferred. User explicitly directed: start Phase 3 from current HEAD without waiting on Phase 2 closeout.

## Task tracker

### 3.1 — OllamaBackend class (~2h)

- [ ] Define `TextLLMBackend` Protocol in `backend/app/engines/llm_backend.py` (`async def polish(text, tone) -> str`)
- [ ] `FlanT5Backend` wrapping current `PolishEngine.polish()` logic unchanged
- [ ] `OllamaBackend` POSTing to `http://localhost:11434/v1/chat/completions` via stdlib `urllib` (zero new pip deps)
  - System prompt: "You clean up dictated speech. Return only the cleaned text, no explanation, no preamble."
  - Per-tone constraint folded into the system role, not user role
  - Connection errors fall back to `apply_tone(light_cleanup(text))` — never surface as 500
- [ ] `VOXFLOW_POLISH_BACKEND` env var selector (`flan_t5` | `ollama`; default `flan_t5` for this sub-phase)
- [ ] Guardrail (`_guardrail_triggered`) stays in `PolishEngine` and wraps **both** backends
- [ ] Unit tests with mocked Ollama responses
- [ ] **Commit**

### 3.2 — Readiness reporting (~1h)

- [ ] Add `ollama_available: bool` to `/v1/ready` response (via `ReadyResponse` schema)
- [ ] Swift Settings shows one-time dismissable nudge when Ollama not detected
- [ ] Persist dismissal in UserDefaults
- [ ] **Commit**

### 3.3 — Settings UI for Local AI Model (~3h)

- [ ] Backend endpoint to query Ollama model list (status pill data)
- [ ] Backend endpoint to proxy Ollama `/api/pull` NDJSON streaming to Swift
- [ ] Swift Settings → "Local AI Model" section with status pill + Pull-model button + native `ProgressView` (bytes)
- [ ] RAM-tiered default model selection:
  - ≥16 GB → `gemma4:e4b-mlx`
  - 8–16 GB → `gemma4:e2b-mlx`
  - <8 GB → regex pipeline only (no Ollama recommendation)
- [ ] `VOXFLOW_OLLAMA_MODEL` env var still overrides
- [ ] Never auto-pull — explicit user action required
- [ ] **Commit**

### 3.4 — Golden tests + tuning (~4h)

- [ ] 5–10 golden polish regression tests in `backend/tests/test_polish_golden.py` (fuzzy assertions)
- [ ] Tune system prompt until guardrail trigger rate < 15% on golden set
- [ ] Measure + document latency for `e2b-mlx` and `e4b-mlx`
- [ ] Flip `VOXFLOW_POLISH_BACKEND` default to `ollama`
- [ ] **Commit**

### 3.5 — FLAN-T5 removal (~1h)

- [ ] Remove `FlanT5Backend` class entirely
- [ ] Remove FLAN-T5 weights download logic from `scripts/download_models.py`
- [ ] Remove FLAN-T5 lazy-load + env vars from codebase
- [ ] Update `CLAUDE.md` (drop FLAN-T5 references)
- [ ] Verify: `grep -r "flan" backend/ --include="*.py"` returns zero non-`__pycache__`, non-`test_` hits
- [ ] Verify: regex `apply_tone(light_cleanup())` remains the guardrail-fallback path
- [ ] **Commit**

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
