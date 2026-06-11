# Polish latency and guardrail results - R2 (2026-06-11)

- **Hardware:** 16 GB Apple Silicon (the primary dev machine)
- **Model:** `gemma4:e4b-mlx` via Ollama, native `/api/chat` endpoint
- **Corpus:** `backend/tests/golden_polish_set.json` (25 cases, all four tones, 5-52 words)
- **Conditions caveat:** measured while a multi-GB `ollama pull` ran in the background and the machine sat near memory saturation; idle-machine numbers will be better than these.

## Headline numbers

| Metric | May baseline (pre-R2) | R2, this hardware | Notes |
|---|---|---|---|
| Warm single request | ~6.4 s | **0.6 s** | healthy runner, idle-ish machine |
| Steady p50 (25-case run) | 6.4 s | **4.7-4.9 s** | two runs: 4655.8 / 4851.4 ms, under active download |
| Steady p95 | 14 s | 30 s (timeout-bound) | see pathology note below |
| Guardrail trips (live) | ~29% | **0/48 samples; <10% bar passed** | live suite 51/51 green |
| Cold load after unload | n/a (frequent) | ~30 s, now once per Ollama restart | `keep_alive: "24h"` honored |

## What changed (code)

1. **Native endpoint** (`/api/chat`): the OpenAI-compat endpoint silently drops `keep_alive` (verified live); the native endpoint honors it (`expires_at` jumps 24 h). `options.num_predict: 512` replaces the ~128-token compat default that truncated long-paragraph polish.
2. **Guardrail retune:** word-level similarity (floor 0.3; was character-level 0.55), length floor 0.3 for >10-word inputs (was 0.6 — correct filler-removal could not pass), concise tone relaxes both floors to 0.15. `degraded_reason` now distinguishes backend_unavailable / echo / guardrail_similarity / guardrail_length.
3. **System prompt ~85 to ~35 tokens.** The filler examples (um, uh, like...) earn their tokens: without them the model under-cleans very-heavy-filler dictations (caught live by `concise_very_heavy_filler`).

## Pathology findings (load-bearing for the roadmap)

- **Prompt eval collapses under memory pressure:** ~5 tokens/second measured (healthy: effectively instant), no prefix caching in the MLX runner, so prompt bulk is pure downside on a pressured machine.
- **The MLX runner degrades under sustained load and can wedge** after abandoned (client-timed-out) requests; an `ollama stop <model>` cycle restores 0.6 s warm requests. The p95=30 s rows are requests that hit the client timeout during degraded phases; their work is wasted and polish silently falls back.
- **Conclusion adopted in code:** a 16 GB machine should not run the 9 GB e4b alongside the Whisper backend. `recommend_ollama_model` tiers retuned: e4b at >= 24 GB, e2b for 8-24 GB.

## Pending follow-up

- `gemma4:e2b-mlx` comparison on this machine (download in progress at the time of writing). Expectation from the tier logic: similar quality class, much better headroom, no thrash. Record its table here when measured.
- R3.4 (provenance) will surface `degraded_reason` in the UI so silent fallback becomes visible.
