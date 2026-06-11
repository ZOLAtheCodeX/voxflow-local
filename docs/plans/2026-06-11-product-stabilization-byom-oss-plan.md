# VoxFlow product plan: stabilization, BYOM, GUI refresh, open-source launch

- **Date:** 2026-06-11
- **Base:** `master` @ `62b569e`
- **Inputs:** `docs/audits/2026-06-11-full-codebase-review.md` (5-agent review, lead-verified); user goals below
- **Status:** DRAFT, awaiting user approval

## Goals (from user)

1. Product-level stability; kill the spontaneous ghost "hello" bug class for good.
2. Optimized and efficient; fix the suboptimal paths (polish latency, guardrail trips).
3. Updated native-macOS GUI/UI.
4. BYOM: users plug in their own models, local (Ollama, LM Studio, llama.cpp, MLX) or cloud API (OpenAI, Anthropic), per task; everything still works offline when cloud/streaming is unreachable; the UI indicates which mode is in use.
5. Feature completion: dictionary/vocabulary that actually shapes recognition, translation, command modes; experimental computer-use handoff.
6. Publish as a polished open-source project.
7. Privacy preserved even when cloud models are used: local model-based PII filtering of all cloud-bound payloads (`openai/privacy-filter`).
8. Experimental "protocol commands": user-defined named macros triggered by voice ("house party protocol" style), running a stored set of steps.

Note on a goal already met: `gemma4:e4b-mlx` via Ollama is already the default polish model (Phase 3, May 2026). No migration needed; R2 tunes how it is *called*, which is where the quality is currently lost.

## Architecture decision: provider routing

Three approaches were considered for BYOM:

**A. Frontend-direct providers** (Swift talks to Ollama/OpenAI/Anthropic directly, backend shrinks to STT). Pros: fewer hops, no Python in the polish path. Cons: duplicates provider logic the backend already half-owns, loses the privacy gate/redaction chokepoint, makes the regex fallback and guardrail live in two places, and breaks the existing private-API consent flow. Rejected.

**B. Backend provider registry with per-task routing chains (recommended).** All LLM traffic keeps flowing through the FastAPI backend. A `ProviderRegistry` maps provider ids to `TextLLMBackend` implementors: `ollama`, `openai_compat` (one class covers LM Studio, llama.cpp server, vLLM, mlx_lm.server via configurable base URL), `openai`, `anthropic`. Each *task* (polish, translate, smart_action, command) gets an ordered fallback chain ending at the regex floor, e.g. `polish: [anthropic, ollama, regex]`. Every response carries provenance: `served_by`, `model_id`, `fallback_depth`, `degraded_reason`. Pros: one chokepoint for privacy/guardrail/fallback, smallest delta from current code (`OpenAICompatBackend` is ~90% of `OllamaBackend`), provenance comes free at the router. Cons: backend stays a hard dependency for text features (it already is), streaming through the hop adds a little latency when we get to it.

**C. Plugin/MCP-style external provider processes.** Maximum extensibility, large surface, premature for a v0.1 OSS launch. Deferred; the registry in B does not preclude it later.

Decision: **B**. Confidence: high. The privacy gate is the deciding factor: cloud providers must pass through consent + redaction, which only works with a single chokepoint.

Configuration: a versioned `providers.json` under `~/Library/Application Support/VoxFlow/` (app-managed, edited via Settings UI; env vars remain as overrides for dev). API keys stay in Keychain, referenced by name from config, passed to the backend per-request as transient fields (same pattern as the Notion PAT).

Local-first invariant, made explicit and tested: with zero network and zero cloud keys, dictation (WhisperKit), cleanup (regex), and every cockpit action either work or degrade with a visible `degraded_reason`. No feature may hard-require a cloud provider.

## Phase R1: stability (kill the ghost, fix verified bugs)

The ghost "hello" fix is layered; phrase lists stop growing.

| ID | Task | Acceptance |
| --- | --- | --- |
| R1.1 | Replace the regex-on-source parity test with a behavioral one: shared JSON fixture of (input, short_audio, expected) cases executed by both pytest and a Swift XCTest. Delete the broken regex test. | Both suites consume the same fixture file; mutation on either side fails its suite. Suite green again. |
| R1.2 | Set WhisperKit `DecodingOptions`: `noSpeechThreshold`, `logProbThreshold`, `compressionRatioThreshold`, temperature fallback. Mirror `no_speech_threshold` on the HF pipeline path. Values tuned against the regression-clip set plus new silence/noise clips. | New golden clips: pure silence, fan noise, keyboard noise produce empty transcripts. Existing clips unregressed. |
| R1.3 | One shared confidence algorithm (coverage-based, all segments) for WhisperKit and backend paths; port `_estimate_confidence` semantics to Swift. | Same clip yields comparable confidence on both backends; unit tests on multi-segment results. |
| R1.4 | Apply the confidence gate at every transcript ingress: extract `TranscriptGate` (filter + confidence + min-duration) and call it from quick dictation, cockpit chunks, and command lane. Align cockpit min chunk to 0.3 s. | Cockpit noise chunk is discarded; gate unit-tested once, used three places. |
| R1.5 | OpenAI STT path: run the hallucination filter, replace hardcoded 0.88 confidence with coverage estimate or provider-reported value. | Filter applies on all STT backends. |
| R1.6 | Fix S1: `.transcribing` branch in `cancelActiveCapture` with task cancellation. | Escape during transcription returns to idle; test. |
| R1.7 | Fix S2: handle `AVAudioEngineConfigurationChange` (device swap) with clean stop/reset. | AirPods disconnect mid-capture recovers; next capture works. |
| R1.8 | Fix S6: make `FnHoldHotkeyService` thread-safe (route monitor callbacks through main). | TSan-clean on hotkey spam. |
| R1.9 | Fix S3, S4, S5, S7, S9, S12 from the audit (semaphore TOCTOU, clipboard-restore race window, per-keystroke backend restarts via debounce/onSubmit, re-insert target, recordingDuration reset, cockpit engine cleanup). | Each with a regression test where testable. |
| R1.10 | Fix S10: remove API keys from `@Published` AppState; read from Keychain at call sites. | Keys absent from AppState; settings round-trip still works. |

Exit gate: full suite green (it is currently red), plus a new "haunted room" manual protocol: 10 hotkey taps in a quiet-but-ambient room, 10 cockpit idle minutes; zero ghost insertions.

## Phase R2: polish quality and latency (Gemma tuning)

| ID | Task | Acceptance |
| --- | --- | --- |
| R2.1 | Add `keep_alive: "24h"` and an output token budget (`max_tokens` ~512) to the Ollama payload. | No truncation on the long-paragraph golden case; no cold-load after 10 min idle. |
| R2.2 | Guardrail retune: word-level similarity (not character), length-ratio floor 0.3 for >10 words, tone-aware exemption for concise, split `guardrail_triggered` into distinct `degraded_reason` values (guardrail vs backend-unavailable vs echo). | Golden-set trip rate <10% with no hallucination regressions; `filler_heavy_sentence` passes. |
| R2.3 | Compress the system prompt (~90 to ~40 tokens); re-measure with `measure_polish_latency.py`; record p50/p95 in the repo. | p50 measurably improved; numbers documented. |
| R2.4 | Expand the golden polish set to ~25 cases covering tones, lengths, filler densities. | `VOXFLOW_OLLAMA_GOLDEN=1` run green on target hardware. |

## Phase R3: BYOM provider architecture (approach B)

| ID | Task | Acceptance |
| --- | --- | --- |
| R3.1 | Extend `TextLLMBackend` Protocol: per-request `model`/`timeout` params; `ProviderRegistry` + real factory replacing `select_backend()`. | Ollama behavior unchanged under registry. |
| R3.2 | `OpenAICompatBackend` (configurable base URL + optional auth header: LM Studio, llama.cpp, vLLM, mlx_lm.server) and `AnthropicBackend`; native `OpenAIBackend` thin subclass of compat. | Live smoke test against LM Studio; unit tests with mocked HTTP. |
| R3.3 | Per-task fallback chains in `ProviderRouter`; regex floor always last; `ProviderMode` enum replaces `normalize_provider_mode` strings. Cloud providers in any chain route through the existing consent + redaction gate. | "anthropic for smart-actions, ollama for polish" expressible; unplugging the network exercises every chain down to local. |
| R3.4 | Provenance fields (`served_by`, `model_id`, `fallback_depth`, `degraded_reason`) on all LLM response schemas and `/v1/ready` (active chain per task, reachability per provider, model-pulled status to close the known Ollama ready-but-missing-model blind spot). | Every response identifies its server; ready endpoint drives the UI indicator. |
| R3.5 | Implement the STT fallback chain (make `stt_fallback_active` real); `OpenAICompatAudioClient` via configurable base URL. | WhisperEngine load failure falls back per config and reports it. |
| R3.6 | `providers.json` config store + Settings "Models" tab UI (provider CRUD, chain ordering, test-connection button, Keychain-backed keys). | Round-trip: add LM Studio provider in UI, polish served by it, indicator updates. |
| R3.7 | Mode-in-use indicator: menu bar panel footer + cockpit pill read provenance from state (replaces the hardcoded `gemma4:e4b-mlx` string). Distinct visual for degraded/fallback. | Kill Ollama mid-session: indicator flips to "regex fallback" within one request. |
| R3.8 | Cloud privacy filter: integrate `openai/privacy-filter` (`opf`, Apache-2.0, 1.5B params / 50M active, CPU-capable, local) as a model-based redaction tier in `backend/app/privacy/`. Enforced at the ProviderRouter chokepoint: any payload bound for a non-local provider passes the active redaction policy (off / regex / model) before leaving localhost. Optional dependency with lazy model download to `VOXFLOW_MODELS_DIR`; regex tier remains the floor when the model is absent (local-first invariant holds). Privacy settings gain a policy picker + operating-point preset (precision/recall); the existing `/v1/privacy/preview` and consent UI render model spans with category labels. Dictionary terms feed an allow-list so profession jargon is not falsely masked. | With policy "model": a transcript containing a name/DOB/address sent through a cloud chain arrives at the provider redacted (assert via mocked HTTP); preview shows labeled spans; with the model absent, regex tier applies and `degraded_reason` says so. |

Deliberately deferred from R3: streaming token output (protocol is designed not to preclude it; revisit after R4 since the floating pill is where partials would render).

R3.8 trade-off, recorded: model-based redaction adds inference latency to every cloud-bound request (single forward pass, CPU-tolerable, but nonzero) and a ~GB-scale optional model download. That cost is opt-in by policy and only on the cloud path; the fully local path never pays it. Counter-argument considered: regex-only is cheaper and already exists, but it cannot catch names, addresses, or free-form identifiers, which is precisely what leaks in dictated speech.

## Phase R4: GUI refresh (native macOS)

| ID | Task | Acceptance |
| --- | --- | --- |
| R4.1 | Floating recording pill: new `RecordingOverlayController` (non-activating borderless `NSPanel`, ~260x56, top-center) showing waveform + timer + target app during `.recording`/`.transcribing`; panel no longer needs to be open. Reuses `recordingStateCard` internals. | Dictating into another app shows live feedback without touching the menu bar. |
| R4.2 | Settings IA restructure: tabbed Settings scene (General / Models / Dictation tools / Privacy / Advanced / Permissions), resizable window, single `SettingsView` instance. R3.6's Models tab lands here. | No section lost; window resizable; state island duplication gone. |
| R4.3 | Retire `MainWindowView` (Settings via ⌘, scenes; Dashboard/Setup as standalone windows). | No duplicate SettingsView instantiation; menu items updated. |
| R4.4 | ⌘K palette to native overlay (panel/popover) with arrow-key navigation + return-to-run. | Full keyboard flow: ⌘K, arrows, return. |
| R4.5 | Menu bar icon state pass: per-state rendered images (recording tint/pulse), template-image compliance for idle. | Recording state visible at a glance in the status bar. |
| R4.6 | Token + a11y debt batch: the ~20 hardcoded stragglers from the audit, new `VF.colorInfo`/spacing tokens, deprecated `.foregroundColor` fix, `TimelineView` for the cockpit timer, VoiceOver labels on chips/tone buttons/waveform/pills. | Zero raw `.blue`/`.orange`/`cornerRadius:` literals in Views/; VoiceOver pass over primary flows. |

## Phase R5: feature completion

| ID | Task | Acceptance |
| --- | --- | --- |
| R5.1 | Dictionary that shapes recognition: feed dictionary terms into WhisperKit prompt biasing (decoder prompt tokens); extend learn-from-edit to quick dictation review; keep post-correction as the second layer. | Golden clip with a seeded term ("GDPR", a surname) transcribes correctly where it previously failed; learning fires from both loops. |
| R5.2 | TTS decision: wire `POST /v1/tts` to a "speak result" action, or delete endpoint + Settings section. Recommendation: delete for v0.1 (no user story; cut surface before OSS). | No inert endpoints at launch. |
| R5.3 | Command lane honesty pass: rename "system command lane" to what it is (in-app voice control); document the intent grammar; small grammar expansion (open cockpit, switch profile, run chain by name). | README/UI no longer oversell; grammar documented + tested. |
| R5.4 | Experimental: assistant handoff ("computer use"). Explicit opt-in mode that sends the transcript to a user-configured agent CLI (e.g. `claude -p`, or any configured command) and shows the response in a review card; never auto-executes, every invocation behind the privacy gate with visible payload preview. Ships off by default behind an "Experimental" settings group. | Round-trip with one configured CLI; cannot fire without explicit per-feature enablement; payload preview shown. |
| R5.5 | Translation: keep EN->DE as-is for v0.1; file the multi-language refactor (`translate(text, source, target)`) as a tracked post-launch issue rather than blocking launch. | Issue written; no regression. |
| R5.6 | Experimental: protocol commands. Voice-triggered named macros built on the existing chain primitives, not a new subsystem: a protocol is a `WorkflowChain` with a voice trigger. (a) Trigger grammar in the command lane and cockpit voice router: the utterance must be the *entire* transcript and match "(run\|start\|execute) <chain name> protocol" or a custom per-chain trigger phrase; matching reuses `ChainStore.normalizedName`. (b) New `ChainStep` kinds for app-internal commands the command lane already routes: `.setMode`, `.setProfile`, `.openWindow`; the existing unknown-kind-throws Codable covers forward compatibility. (c) Optional `.handoff` step delegating to the R5.4 assistant handoff, inheriting all of its gating. Safety: protocol triggers sit behind the R1 `TranscriptGate` at a stricter threshold (exact full-utterance match plus a confidence floor) so a hallucinated transcript can never fire a macro; any protocol containing a `.handoff` step shows a step-list confirmation card before each run; the whole feature ships off by default in the Experimental settings group. | Say "run memo protocol" in the command lane: the Memo chain executes; a partial or low-confidence match does nothing; a `.handoff` protocol cannot run without the confirmation card; feature absent unless the experimental toggle is on. |

R5.4 carries real risk (prompt-injection via dictated text into an agent with execution rights). Mitigation: handoff sends text and renders text; execution authority stays entirely in the external agent's own permission model; VoxFlow never wraps it. Counter-argument: skip R5.4 for launch entirely. It stays last and cuttable. R5.6 inherits the same posture for its `.handoff` step; its app-internal steps (mode/profile/window) are reversible and carry no execution authority. Deliberately excluded from R5.6: a raw `.shell(command)` step kind; dictated speech driving unconfirmed shell execution is an unacceptable injection surface for v0.1, and the assistant-handoff path covers the use case with an agent's own permission model in between.

## Phase R6: open-source launch

| ID | Task | Acceptance |
| --- | --- | --- |
| R6.1 | LICENSE (recommendation: MIT; Apache-2.0 if patent grant matters to you, decide before any external contribution arrives). | File in root; headers where conventional. |
| R6.2 | Repo hygiene: untrack `progress.*`, `*_tests*.log`, `.cursorrules`; `.gitignore` additions; decide public fate of CLAUDE.md/AGENTS.md (recommendation: keep a trimmed CONTRIBUTING-oriented version, move agent internals out). | Fresh clone contains no dev droppings. |
| R6.3 | CI: GitHub Actions, macOS runner: `swift build`+`swift test`, `pytest` (model-dependent tests skipped via existing markers), lint. Badge in README. | Green on a clean runner. |
| R6.4 | Community files: CONTRIBUTING.md (test commands, branch/commit conventions), SECURITY.md, CODE_OF_CONDUCT.md, issue/PR templates, CHANGELOG.md seeded at v0.1.0. | Present and accurate. |
| R6.5 | README rewrite for outsiders: what it is (local-first dictation), 60-second quickstart, honest model-size callout (~24 GB optional, what each model enables), Ollama requirement for polish, BYOM matrix, demo GIF of the recording pill + insert. | A stranger reaches first dictation following only the README. |
| R6.6 | Release pipeline (P7): `release_signed.sh` to DMG, notarization documented, unsigned-build path for non-Apple-developer users documented, tag v0.1.0. | Notarized DMG installs and passes Gatekeeper on a second Mac. |

## Sequencing and execution

```
R1 (stability)  ──►  R2 (polish tuning)  ──►  R3 (BYOM, backend-heavy) ──► R5 (features)
                                         └──► R4 (GUI, Swift-views-heavy)      │
                                                          └────────────┬───────┘
                                                                       ▼
                                                                R6 (OSS launch gate)
```

- R1 is first and non-negotiable: the suite is currently red and the ghost bug is the product's reputation risk.
- R3 and R4 touch disjoint trees (backend/routing vs Views/) and suit the established parallel-worktree swarm workflow; R3.7 and R4.x integrate at the AppState seam, so land R3.4 (provenance) before R3.7/R4 integration.
- R6 is strictly last; launching before R1/R2 ships known hauntings.
- R3.8 depends on R3.3 (the chokepoint) and should land before any cloud provider chain is documented as recommended. R5.6 depends on R1.4 (`TranscriptGate`) and, for its `.handoff` step only, on R5.4.
- Each phase = one or more PRs with the existing review pipeline (TDD-red where applicable, spec review, parallel boundary/adversarial reviews).
- Rough scale (working sessions, not calendar): R1 ~3-4, R2 ~1, R3 ~5-6 (R3.8 ~1 of those), R4 ~3-4, R5 ~3-4 (R5.4 +2 if kept, R5.6 ~1), R6 ~2.

## Assumptions and risks

- Assumes WhisperKit's current API exposes the decoding thresholds and prompt-token biasing used in R1.2/R5.1; verify versions at R1 start (high confidence for thresholds, medium for prompt biasing; if biasing is unavailable, R5.1 falls back to post-STT correction in both loops plus a documented limitation).
- Guardrail/threshold tuning (R1.2, R2.2) is empirical; budget includes a measurement loop on the user's hardware, and golden clips are the regression net.
- Concurrent-session etiquette: another session sometimes commits to master; all phase work in isolated worktrees, merges gated on a fresh master check (established workflow).
- Anthropic/OpenAI backends (R3.2) need live keys for smoke tests; unit layers are mocked so CI never requires keys.
