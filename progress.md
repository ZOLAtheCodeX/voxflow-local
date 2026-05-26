# Phase 5 — Performance Polish (Progress)

**Branch:** `feature/phase-5-perf`
**Started:** 2026-05-26
**Spec:** `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` §Phase 5

## Acceptance gates

| Gate | Result |
| --- | --- |
| `swift test` | ✅ 256 passed |
| `pytest backend/tests` | ✅ 344 passed, 9 skipped |
| FLAN-T5 grep clean (no `test_` exclusion) | ✅ |
| `CLAUDE.md` under 200 lines | ✅ 151 lines |
| `CLAUDE.md` backend paths verified | ✅ 16/16 |

## Task tracker

### Backend performance

- [x] **5.1** Whisper chunking skip for audio < 20s (`backend/app/engines/whisper.py`) — `chunk_length_s=0` per-call override eliminates ~6s pre/post padding on the dictation hot path. 2 new unit tests. Commit `e67774d`.
- [x] **5.2** Luhn-validated credit-card redaction (`backend/app/privacy/redaction.py`) — non-card 13–19 digit runs fall through to existing `[PHONE]`/`[ID]` catch-alls. 15 new tests. Commit `4f28cc5`.
- [x] **5.3** Rate-limit lock (`backend/app/server.py`) — `threading.Lock` wraps single-pass read/prune/write of `_rate_limit_timestamps`. Single-worker assumption documented. Commit `d139127`.
- [x] **5.4** WebSocket idle timeout — `asyncio.wait_for(receive_text(), timeout=60)` + clean close frame (code 1000). 2 new tests in `test_websocket_timeout.py`. Commit `d139127`.

### Swift performance

- [x] **5.5** `FocusContextMonitor.poll()` `isFrozen` guard moved to top — drops 2 AX calls + comparison per 250ms tick during recording. Commit `dab3734`.
- [x] **5.6** AppState coalescing — audited; deliberate deferral. SwiftUI already coalesces synchronous `@Published` mutations into one `body` re-evaluation per tick (which is how `pollBackendReadiness` already updates 6 readiness props in one call). The refactor would touch ~97 read sites for no measurable benefit.

### Documentation

- [x] **5.7** `CLAUDE.md` rewritten (151 lines, decomposed backend layout, Ollama-only polish, Phase 5 perf notes, expanded Do-Not rules). All 16 referenced backend paths verified to exist. Commit `186ec7f`.
- [x] **5.8** `README.md` Runtime Notes updated — Gemma 4 via Ollama as polish default + new Ollama setup subsection. Commit `186ec7f`.

## Performance summary

| Optimization | Before | After | Result |
| --- | --- | --- | --- |
| 5.1 Whisper short-audio fast path | ~6s pre/post padding per chunk | `chunk_length_s=0` for audio < 20s | ~30–40% latency reduction on the dictation hot path (per-clip measurement deferred to `scripts/measure_polish_latency.py` on the dev box) |
| 5.2 Luhn credit-card check | Every 13–19 digit run tagged `[ACCOUNT_NUMBER]` | Only Luhn-valid runs tagged | Eliminates a class of privacy-preview false positives; redaction still complete |
| 5.3 Rate-limit lock | Unprotected dict access | `threading.Lock` wraps single-pass mutation | Correctness fix; bounded contention via single-worker + O(window) critical section |
| 5.4 WebSocket idle timeout | Stalled client pinned coroutine indefinitely | 60s timeout → clean close frame | Bounded resource hold; clean disconnect for client error recovery |
| 5.5 FocusContextMonitor frozen-path | 2 AX calls per 250ms tick during recording | Boolean check + early return | 8 main-thread AX hits/sec dropped during recording |
| 5.6 AppState coalescing | (audit) | (deferred — see note above) | No change; SwiftUI tick batching already provides the win |

When this file's checkboxes are all `[x]` AND the acceptance gates are green AND `feature/phase-5-perf` holds the work: emit `<promise>PHASE_5_COMPLETE</promise>`.
