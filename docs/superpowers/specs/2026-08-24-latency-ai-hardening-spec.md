# Latency + AI-features hardening (session 32) — design spec

Source: field-receipt and live-Ollama review on 2026-08-24 (findings recorded in
session memory `latency-review-2026-08-24`) plus an independent UI audit the
user pasted; user decisions taken via AskUserQuestion.

## Measured facts driving this work

- 1,800 receipts since v0.1.3: 98.4% inserted, 100% of inserts `light · rules`.
  No Gemma polish and no smart action reached the field.
- Gemma 4 via Ollama (`/api/chat`) thinks by default. Warm 30-word polish:
  ~6.0 s with ~370 hidden thinking tokens; 257–533 ms with `"think": false`.
  Thinking tokens count against `num_predict`.
- `PolishEngine.run` skips LOCAL providers at `kern.memorystatus_vm_pressure_level >= 2`
  for smart actions too. The user's 16 GB machine rests at level 2, so smart
  actions always return `provider_unavailable`, and the UI says "configure a
  provider" (the real reason is dropped in `SmartActionEngine.apply`).
- Ollama `:cloud` models (`remote_host: https://ollama.com` in `/api/tags`) are
  classified LOCAL by `ProviderSpec.is_cloud` → no redaction, memory-guard-skipped.
- `CapturePipelineTrace` stage timings are computed and never persisted or shown.
- Loopback `/v1/cleanup` (rules) p50 1.0 ms; backend idles at 88 MB. Neither is
  a latency/memory factor. Python `nlp/cleanup.py` omits the POS-aware
  ambiguous-filler pass that Swift `TextCleanupService` has.
- Cockpit smart actions have no in-flight state; duplicate dispatch is possible.

## Decisions (user-approved)

1. `think: false` on every Ollama chat request. Env `VOXFLOW_OLLAMA_THINK=1` re-enables.
2. Memory guard: polish (dictation hot path) keeps skipping local providers at
   level ≥ 2; smart actions (system_prompt path) skip only at level ≥ 4
   (critical). `degraded_reason` propagates to the smart-action refusal and the
   cockpit shows the honest reason.
3. Ollama models tagged `:cloud` are CLOUD: redaction on, memory guard off.
4. Insert receipts gain `stt_ms`, `cleanup_ms`, `insert_ms`, `total_ms`,
   `insert_method`. Total = hotkey release → insert complete.
5. Rules-only polish (`activePolishProvider == "rules"`) is served in-app by
   `TextCleanupService` (light AND polish modes, and review), never via the
   backend. Provenance label `rules · in-app`.
6. Cockpit single-flight smart actions: `AppState.smartActionInFlight` +
   `smartActionStartedAt`; chips disabled while running; top-bar pill with
   elapsed seconds; a second dispatch returns soft error `action_in_flight`.

## Non-goals (this session)

Progressive review mode, bundle slimming, AVAudioSinkNode capture start,
AX-skip heuristic, paste-path restructure, STT model changes. Logged for the
Notion backlog.

## Constraints

- Swift 6.2 strict concurrency; macOS 14+. Python 3.11.
- No new Python deps. Keep `HallucinationFilter`/rules parity untouched.
- Tests never construct real system-touching services (use `TextInserting`,
  `SmartActionBackend` seams).
- Every Swift `SmartActionResult` memberwise call site (19) must keep compiling:
  new fields get defaults.
