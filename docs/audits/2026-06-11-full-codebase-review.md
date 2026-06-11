# Full codebase review - 2026-06-11

- **Base:** `master` @ `62b569e`
- **Method:** 5-agent parallel review (ghost-hello pipeline trace, backend/BYOM architecture, UI/UX, feature completeness + OSS readiness, critical-path bug hunt), with lead verification of all critical claims by reading source and executing tests.
- **Verified live:** the hallucination-filter parity test **fails on master right now** (`pytest backend/tests/test_utils.py -k parity` reproduces). The Python suite is not green.
- **Companion plan:** `docs/plans/2026-06-11-product-stabilization-byom-oss-plan.md`

## Executive summary

The product core is in better shape than the user's perception suggests: every headline feature (dictation, per-app profiles, snippets, cockpit, chains, Notion, translation, meeting mode, privacy gate) is fully wired end to end, scripts are portable, no secrets are committed, and `gemma4:e4b-mlx` is already the default polish model (the requested "mlx gemma update" shipped in May's Phase 3). Confidence: high, verified by production call-site tracing.

What is actually wrong falls into five buckets:

1. **The ghost "hello" survives because the anti-hallucination defense has holes in every layer** (details in section 1). The phrase-list parity test between Swift and Python has been broken since the Swift filter rewrite and is failing on master.
2. **A set of verified stability bugs** in the capture/insert/settings paths, three of them critical for a daily driver (section 3).
3. **Polish quality is self-sabotaged**: the guardrail trips ~29% largely on legitimate filler-removal output, and the Ollama request sets neither `keep_alive` nor a token budget, so outputs truncate at the 128-token default and the model cold-loads after idle gaps (section 2).
4. **BYOM does not exist yet**: `select_backend()` always returns Ollama regardless of configuration, no response carries provenance, and there is no per-task routing (section 4).
5. **The UI is functional but not Wispr-Flow-class**: no floating recording indicator (all feedback trapped in the menu bar panel), Settings is a single 15-section scroll, the ⌘K palette is a mis-presented `.sheet` with no keyboard navigation, and `MainWindowView` is a redundant architectural artifact (section 5).

Open-source readiness is close: the blocking gap is the missing LICENSE; the rest is hygiene (CI, community files, tracked dev artifacts) (section 6).

## 1. Ghost "hello" root-cause analysis

Ranked, with confidence levels. The bug is real and has multiple independent contributors; fixing any one of them reduces frequency but only the layered fix eliminates it.

| # | Cause | Evidence | Confidence |
|---|---|---|---|
| 1 | **Parity test dead since Swift rewrite.** Regexes in `backend/tests/test_utils.py:490-503` match old variable names (`alwaysFiltered`); Swift now uses `alwaysFilteredSingleWords` (`HallucinationFilter.swift:4`). Test fails on master; filter drift is unenforced. | Executed: test fails | Verified |
| 2 | **Multi-word hallucinations pass both filters.** "Hello world", "hello how are you" pass Swift (`HallucinationFilter.swift:40-60`, only 1-2 word and template checks) and Python (`nlp/hallucination.py`, exact-phrase sets). Whisper on noise frequently emits multi-word greetings. | Read both filters; behavior table built | High |
| 3 | **No model-level no-speech gating.** `WhisperKitSTTService.swift:50-54` sets only `language` and `wordTimestamps` in `DecodingOptions`; `noSpeechThreshold`, `logProbThreshold`, `compressionRatioThreshold`, temperature fallback all unset. Backend HF pipeline (`engines/whisper.py:203-206`) likewise passes no `no_speech_threshold`. Whisper will transcribe something from silence/noise. | Read both configs | High |
| 4 | **Swift confidence is not coverage-based.** `WhisperKitSTTService.swift:60-65` uses `exp(avgLogprob)` of the *first segment of the first result*; a hallucinated phrase from noise lands ~0.3-0.6, sailing past the 0.15 single-word gate in `AppCoordinator.swift:677-685`. The Python side's coverage penalty (`whisper.py:101-133`) was the session-16 "fix" but was never ported to the WhisperKit path, which is the default backend. | Read both | High |
| 5 | **Cockpit path bypasses the confidence gate entirely.** `CockpitCaptureCoordinator.swift:67-97` checks only RMS silence and a 0.25 s minimum (shorter than the 0.3 s quick-dictation gate); the `isSuspect` gate exists only in `AppCoordinator.handleTranscriptionResult`. Every 5 s flush of ambient noise is an opportunity. | Read | High |
| 6 | **RMS silence threshold (0.003) admits ambient noise.** `AudioCaptureService.swift:28-30`. Fan/HVAC/keyboard rooms run 0.005-0.02 RMS, so "silent" rooms still reach Whisper. Deliberate (quiet-speaker support) but unmitigated by layers 3-4 above. | Read | High |
| 7 | **OpenAI STT path has no filter and hardcodes confidence 0.88.** `endpoints.py:165` skips the hallucination filter for `stt_backend == "openai"`; `whisper.py:354` hardcodes 0.88, defeating the gate. | Read | High (low exposure: non-default backend) |

**Direction of the durable fix** (argued in the plan): stop extending phrase lists; add layered gating instead. (a) model-level no-speech/logprob thresholds, (b) one shared coverage-based confidence implementation on both paths, (c) the confidence gate applied at every transcript ingress including cockpit chunks, (d) a behavioral (not regex-on-source) parity test.

## 2. Polish quality and latency (Ollama/Gemma path)

- **Guardrail trips ~29% mostly on correct output.** `polish.py:116-132`: character-level `SequenceMatcher` threshold 0.55 plus a length-ratio floor of 0.6 for inputs over 10 words. Correct filler-removal ("um so basically i think we should kind of you know maybe consider rescheduling" to "We should reschedule the meeting") produces ratios of 0.3-0.4 and trips it. The golden set's own `filler_heavy_sentence` case (17 to 6 words, ratio 0.35) can never pass. Confidence: high.
- **No `keep_alive` in the request payload** (`llm_backend.py:115-124`): the model unloads after 5 idle minutes and cold-loads (multi-second p95 spikes). The env-var workaround exists but per-request `keep_alive` is a tighter guarantee.
- **No output token budget set**: Ollama's OpenAI-compat endpoint defaults to ~128 tokens; long-paragraph polish truncates, which then trips the guardrail or ships cut-off text. Verified: payload contains only model/messages/stream/temperature.
- **Guardrail conflates causes**: `guardrail_triggered: true` is returned whether Ollama was unreachable, the output was degenerate, or it was a legitimate trip. No provenance field exists to distinguish (see section 4).

## 3. Verified stability bugs (critical path)

Critical findings verified by the lead by reading the cited code; high findings spot-checked or consistent across two agents.

| # | Sev | Location | Bug |
|---|---|---|---|
| S1 | Critical | `AppCoordinator.swift:779-803` | `cancelActiveCapture()` has no `.transcribing` branch (verified: branches exist only for recording/privacy/review/error). Escape during a slow transcription does nothing; user perceives a hang. |
| S2 | Critical | `AudioCaptureService.swift` | No `AVAudioEngineConfigurationChange` handling. AirPods connect/disconnect mid-capture silently stops the engine; subsequent captures fail from inconsistent engine state. |
| S3 | Critical | `endpoints.py:150-154` (x5 endpoints) | `if sem.locked(): 503` then `async with sem:` is a TOCTOU; the concurrency cap can be exceeded. Low blast radius for a single user, but it is the kind of latent bug that bites under cockpit chunking + quick dictation overlap. |
| S4 | High | `AccessibilityInsertService.swift:96-131` | Paste fallback saves/restores the clipboard around a 300 ms window; a user copy in that window is destroyed. |
| S5 | High | `SettingsCoordinator.swift:327-350` | Every settings mutator triggers a backend restart; typing an API key restarts the backend per keystroke (config delta per character). |
| S6 | High | `FnHoldHotkeyService.swift:57-73` | Global event-monitor callback mutates `isFnAlonePressed`/`hasTriggeredPress` from a background thread while a main-queue work item reads them. Data race on the primary hotkey path. |
| S7 | High | `AppCoordinator.swift:1163-1171` | `insertRecentDictation` passes `targetApp: nil`, so re-insert resolves the frontmost app at click time (the VoxFlow panel itself). |
| S8 | High | `WhisperKitSTTService.swift:60-65` | Confidence from first segment only (also ghost-hello cause #4). |
| S9 | High | `DictationWorkflowCoordinator.swift:59-66` | `autoInsertRaw` path never resets `recordingDuration`; stale timer shown. |
| S10 | Medium | `SettingsCoordinator.swift:102` + AppState | API keys held in `@Published` AppState strings (Combine-broadcast, memory-dump exposure). Keychain rule honored at rest, violated in flight. |
| S11 | Medium | `server.py:186` vs `context.py:202` | Duplicate `_LAST_CLEANUP_TIME` globals; the `context.py` one is dead. Contributor confusion hazard. |
| S12 | Medium | `CockpitCaptureCoordinator.swift:76-85` | Chunk-restart failure path does not stop the capture engine; next session starts from unknown engine state. |

## 4. BYOM gap analysis (backend)

What exists: `TextLLMBackend` Protocol with a single `polish(text, tone, system_prompt)` method; `OllamaBackend` as sole implementor; `ProviderRouter` with a two-way `local_only` / `private_api` branch; `OpenAIAudioClient` for cloud STT.

Verified gaps blocking the user's BYOM vision:

1. `select_backend()` (`llm_backend.py:197-217`) ignores `VOXFLOW_POLISH_BACKEND` and always constructs `OllamaBackend`. No registry, no factory.
2. No provenance anywhere: `CleanupResponse`, `SmartActionResponse`, `TranslateResponse`, `MeetingSummaryResponse` (`schemas.py`) carry no `backend_name`/`model_id`/`fallback_depth`. The UI cannot show "which mode in use", and guardrail vs unavailable vs echo are indistinguishable.
3. Protocol has no per-request model/timeout parameters and no streaming method.
4. No per-task routing: polish, translate, smart-actions, meeting all share one `polish_engine` singleton; "OpenAI for polish, local Marian for translate" is inexpressible.
5. `normalize_provider_mode` (`routing/utils.py:15-19`) collapses everything to two string modes; adding providers means editing three call sites.
6. `stt_fallback_active` (`provider.py:135-136`) always returns `False`; the `/v1/ready` field is a dead signal and no STT fallback chain exists.
7. `PolishEngine.is_available()` hardcodes the Ollama probe and returns `True` for any other backend name (silent un-checking of future backends).
8. Cheap wins noted: STT BYOM is nearly free (LM Studio exposes OpenAI-compatible `/v1/audio/transcriptions`; `OpenAIAudioClient` needs only a configurable base URL). `OpenAICompatBackend` for text is ~90% of `OllamaBackend`.

## 5. UI/UX assessment

Full inventory in agent report; condensed here. The token system (`VFDesignTokens`) is genuinely good and mostly enforced; the gaps are structural.

Ranked gaps vs a Wispr-Flow-class product:

1. **No floating recording indicator.** All recording feedback lives inside the 430 px menu bar panel; while dictating into another app there is zero on-screen feedback beyond a swapped SF Symbol in the status bar. This is the single highest-leverage UI change. The waveform/timer UI already exists in `recordingStateCard` and needs extraction into a non-activating floating `NSPanel`.
2. **Settings is one 15-section scrolling Form** at a fixed 520x420 (`SettingsView.swift`, ~936 lines). Needs tabbed IA: General / Models / Dictation tools / Privacy / Advanced / Permissions.
3. **⌘K palette is a `.sheet` with no keyboard navigation** (`ActionPaletteView.swift`, fixed 440x320). Wrong macOS idiom for a command palette; needs panel/popover presentation plus arrow-key + return handling.
4. **`MainWindowView` is redundant**: a TabView duplicating Settings/Dashboard/Setup that all exist as scenes, and it instantiates a second independent `SettingsView` state island.
5. **Mode-in-use is invisible or wrong**: `CockpitTopBarView:31` hardcodes the string `"gemma4:e4b-mlx"` (verified) rather than reading state; no surface shows STT backend, polish provider, or fallback status during normal use. Depends on the provenance work in section 4.
6. **Menu bar icon state feedback is symbol-swap only** (no animation/tint for the recording moment).
7. **Token/a11y debt**: ~20 hardcoded color/radius/padding stragglers (list in agent report, e.g. `CommandPaletteView.swift:271,336,442`, `DashboardWindowView` corner radii x5, `SetupWizardView` x5, deprecated `.foregroundColor` in `ModeChip.swift:21`); VoiceOver labels missing on chips, tone buttons, waveform, cockpit pills; `CockpitTopBarView` elapsed timer never refreshes (no `TimelineView`).
8. **No live partial transcript while recording** (requires streaming STT; aspirational, the rest does not depend on it).

## 6. Feature completeness and OSS readiness

Feature matrix: everything claimed in the README is fully wired except:

- **Dictionary** is post-STT correction only, applied in the cockpit path only; it does not bias WhisperKit decoding (no prompt biasing) and does not learn in quick dictation. Biggest "feature not fully built out" confirmed.
- **TTS endpoint** (`POST /v1/tts`) plus its Settings section is inert: zero Swift callers. Wire it or cut it.
- **Command lane** is an in-app intent router (mode/provider/backend switching by voice), not system command execution. The README's "system command lane" phrasing oversells it; the user's "computer use" ambition is a new feature, not a completion.

OSS launch gaps, by priority:

| Priority | Item |
|---|---|
| Blocking | No LICENSE (default all-rights-reserved) |
| High | No CI (.github/workflows: swift test + pytest), no CONTRIBUTING.md, no SECURITY.md, no CHANGELOG.md |
| High | Tracked dev artifacts: `progress.md`, `progress.txt`, `python_tests*.log`, `swift_tests*.log`, `.cursorrules`; decide fate of `CLAUDE.md`/`AGENTS.md` for the public repo |
| Medium | CODE_OF_CONDUCT, issue templates, README clarity (24 GB models dir, Ollama effectively required for polish, gated HF models), signing/notarization docs + DMG pipeline (P7) |
| Clean already | No secrets committed, scripts portable (BASH_SOURCE-relative), tests runnable on fresh checkout, models properly git-ignored with a download script |

Counter-argument worth recording: shipping OSS *before* the GUI refresh would maximize early feedback, and some maintainers prefer that. Recommendation remains stability first, OSS gate last: first impressions of a dictation tool hinge on the ghost-text bug class, and "known haunted" is a bad launch review.
