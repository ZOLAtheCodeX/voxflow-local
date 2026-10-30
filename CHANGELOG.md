# Changelog

All notable changes to VoxFlow Local are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) once past 1.0.

## [Unreleased]

### Fixed
- Cmd+R in the cockpit is never ignored silently. In review it now says
  "Still reviewing. Insert with ⌘↩, or Discard to start a new recording.",
  and a microphone that will not start says why instead of doing nothing.
  This was the main v0.1.4 known issue: closing the cockpit while recording
  keeps the transcript for review, so the next Cmd+R often landed in review.
- Review has a visible Discard button next to the review pill (the spoken
  "cancel" does the same). It returns the cockpit to ready without
  inserting; the session file stays in VoxFlow's sessions folder, and a
  notice says so. Discard is refused while recording, so it can never leave
  the microphone running.
- The first smart action after Ollama unloads the model no longer times
  out. Smart actions now get at least 90 seconds per request (the cold load
  measured about 35 s against the provider's 30 s), and the stuck-runner
  breaker measures against the same budget, so a slow cold load no longer
  counts as a wedge. Dictation polish keeps the provider's timeout.

### Security
- transformers bumped 5.5.0 → 5.17.0, closing CVE-2026-9856 (path traversal
  in tokenizer and processor `save_pretrained`) and CVE-2026-80047 (custom
  generation code written to disk before the trust check). Neither is
  reachable as configured: VoxFlow never calls `save_pretrained`, never passes
  `custom_generate` or `trust_remote_code`, and keeps Hugging Face Hub access
  offline. 5.17.0 is the first release with the CVE-2026-80047 fix; the
  advisory's "<= 5.8.1" range is wrong, so 5.10.x would have cleared the
  alert while still writing the file before consent.
- torch bumped 2.10.0 → 2.14.1 and torchaudio 2.10.0 → 2.11.1, closing
  CVE-2025-3000 (memory corruption in `torch.jit.script`). Not reachable:
  VoxFlow never scripts code, and its only TorchScript load is Silero VAD's
  bundled model. The advisory names 2.13.0 as patched, but the upstream
  reproducer still crashes there; 2.14.0 is the first fixed release.
  torchaudio moves because every earlier release pins torch exactly.
- Validated against the real-model STT regression suite, three runs per pin
  set: 14/14 clips on every run with identical transcripts, p50 median
  708 ms vs the old pins' 704 ms.

## [0.1.4] — 2026-10-29

A trust and correctness release: the local backend answers only the VoxFlow
app, the cockpit no longer loses words when you stop, insert, close or run
an action mid-recording, and a root-caused Whisper decode fault no longer
drops speech after a pause or puts sound labels in your text. Vocabulary
gained priorities, import and export; spoken skill profiles, built-in voice
actions and automatic Enter arrived, the last two off by default; and Gemma
polish is about 20 times faster with hidden reasoning off.

### Security
- The local backend now accepts only the VoxFlow app (via a per-launch
  token) and refuses browser-originated, wrong-host, and non-JSON requests,
  closing a blind cross-site request path and DNS rebinding. Scripts read the
  token from `~/Library/Application Support/VoxFlow/backend.token`.

### Fixed
- Short dictations no longer disappear because of WhisperKit's one-second
  window padding: short clips now decode and pass the same transcript gates.
- Insertion stays on the process, window and field you dictated into instead
  of consulting Accessibility elements outside the captured target.
- A release-app crash from menu updates made off the main thread is fixed.
- Dictation no longer drops words when your dictionary terms bias recognition:
  a decode that went wrong is retried once without the glossary, which had
  made Whisper skip speech at the end of a pause.
- Whisper's sound labels (`[BLANK_AUDIO]`, `[Silence]`, `(water rushing)`) no
  longer end up in your text, and a chunk of room noise that Whisper only
  labels is no longer inserted.
- Cockpit chunks that were rejected but contained speech now keep their
  audio in the rejected-audio folder, so nothing is lost without a trace.
- Cockpit dictation no longer loses its last words when you stop: stopping
  drains the tail, a double stop is safe, and Cmd+Return while still recording
  inserts everything that was said.
- Cockpit paragraph breaks now appear only at real pauses in your speech, and
  chunks no longer glue words together.
- The cockpit inserts into the app you came from, and never into a different
  app that happened to reuse its process id.
- The shipped "Memo" and "Action items" chains now run on the current
  transcript instead of sending an empty one.
- Closing the cockpit while recording no longer leaves the microphone on:
  the recording stops and the transcript stays for review.
- A smart action tapped while recording no longer drops the words dictated
  while it runs: the recording stops first and the action works on the whole
  transcript.
- Building the app no longer adds another "VoxFlow" to Spotlight and the app
  launcher: the staging bundle now lives in `dist.noindex/`, which Spotlight
  skips, and installing unregisters it so only `~/Applications/VoxFlow.app`
  answers `open -b local.voxflow.app` and `voxflow://` links. The old
  `dist/.metadata_never_index` marker never worked on a folder. Delete any old
  `dist/` folder by hand.
- Gemma polish and smart actions no longer spend seconds on hidden
  "thinking": Ollama chat requests now send `think: false`. Measured on
  gemma4:e2b-mlx (M1 Pro 16 GB): a warm 30-word polish took 6.0 s with
  ~370 hidden reasoning tokens vs 0.26 s without; the 24-case golden
  benchmark now runs at p50 327 ms / p95 654 ms steady (cold load 7.0 s).
  `VOXFLOW_OLLAMA_THINK=1` re-enables reasoning.
- Smart actions work on 16 GB machines again: the memory-pressure guard
  skips local providers for smart actions only at CRITICAL pressure
  (polish on the dictation hot path still yields at WARN, where such
  machines rest). A refused action now says why (memory pressure / wedged
  runner / no provider) instead of "configure a provider".
- Ollama `:cloud` models (e.g. `kimi-k3:cloud`) are classified as cloud:
  payloads are PII-redacted first and the memory guard no longer skips
  them (they use no local RAM).

### Added
- Vocabulary editing with recognition priorities, text and JSON import with
  a conflict preview, export, and atomic saves. Correcting against 1,000
  entries dropped from 9.98 ms to 0.89 ms median (correction only, not STT).
- Spoken skill profiles map spoken names and aliases to exact CLI commands,
  restricted to the apps you allow. See `docs/vocabulary-and-skills.md`.
- Voice Action Prompts can run twelve registered computer actions (app opens
  and editing shortcuts), each with its own switch, and can require the
  "Voxflow" prefix or accept complete commands without it. Defaults: custom
  prompts only, prefix required.
- Optional automatic Enter after insertion: Off (default), Voice Action
  Prompts only, ordinary dictation only, or both. Direct computer actions
  never press Enter.
- Insert receipts can keep a digest or only a character count instead of the
  dictated text (`defaults write local.voxflow.app VoxFlow.auditTextRetention
  digest`, or `none`). The default stays `full`, and rejections follow the
  same setting.
- Insert receipts carry `stt_ms`, `cleanup_ms`, `insert_ms`, `total_ms`
  (from hotkey release) and `insert_method`, so field latency is finally
  observable per capture.
- "Local rules only" polish is served in-app by the Swift pipeline
  (provenance `rules · in-app`): no backend round trip, and it includes the
  POS-aware filler pass the Python floor omits.
- Cockpit smart actions are single-flight: chips disable and the top bar
  shows the running action with elapsed seconds; a second dispatch is
  refused with a soft error instead of queuing a duplicate transform.

## [0.1.3] — 2026-07-13

A forensics and rules-first release: the field-reported capture-loss class
was root-caused and instrumented (rejected audio retained, receipts
enriched), a four-agent stability review closed 23 verified findings, and
the rules/regex pipeline became a first-class citizen — visible per capture
in the new pipeline viewer, selectable as a never-load-an-LLM polish mode,
and measurably better at healing real dictation artifacts.

### Added
- Capture-loss forensics: rejected captures are retained as WAV clips
  (newest 8, local-only, `~/Library/Logs/VoxFlow/rejected_audio/`, disable
  with `VOXFLOW_KEEP_REJECTED_AUDIO=0`) so a failed dictation is both
  diagnosable and recoverable; reject receipts point at the clip
  (`audio_file`) and the status line notes "(audio kept)". Receipts also
  gained per-insert audio stats, wall-clock coverage
  (`expected_audio_seconds`), partial-decode tail gaps
  (`tail_gap_seconds`), and `device_changed` entries for captures lost to
  a mid-capture input switch.
- Mid-capture stall detection: if the input device stops delivering
  buffers for 2 s while recording, the capture stops and transcribes what
  arrived instead of letting you speak into a dead engine; material
  coverage shortfall is called out in the status line.
- Quiet-boundary cockpit flush: long-form chunk cuts defer (bounded, up
  to 2 s) until the audio tail goes quiet, so 5 s seams land between
  words instead of through them; sub-minimum chunks carry into the next
  flush instead of being dropped.
- Ollama wedged-warm circuit breaker: two consecutive timeout-shaped
  polish failures skip the provider for 120 s
  (`degraded_reason: provider_wedged`) instead of stalling every
  dictation 30 s until a manual `ollama stop`.
- Silero VAD speech-presence detection (~2 MB, bundled offline in the
  wheel): a gate in front of whisper-backend decode stops noise-only audio
  from ever reaching the model (Whisper hallucinates text from non-speech;
  the RMS energy gate can't tell noise from speech), and a new local-only
  `/v1/audio/diagnose` endpoint upgrades the empty-capture status line to
  "speech detected but too quiet — raise your input level" vs "background
  noise only" vs "speech but not recognized". Fail-open at every layer:
  a VAD problem can never block transcription or change a message.
  Disable the decode gate with `VOXFLOW_VAD_GATE=0`.
- Memory-aware polish degradation: under OS memory pressure the polish
  chain skips LOCAL providers so the resident LLM never competes with live
  capture for unified memory on constrained machines — cloud providers
  still run, and the provenance pill shows the degradation
  (`degraded_reason: memory_pressure`). Disable with
  `VOXFLOW_POLISH_MEMORY_GUARD=0`.
- Pipeline viewer: persistent last-capture provenance row in the command
  palette and a Recent Captures section in the Dashboard (mode, served-by,
  target, duration, confidence, reject reason, reveal-retained-audio), read
  from `insertions.jsonl`. Read-only; no capture-path changes.
- "Local rules only" polish setting: a reserved `rules` chain id that serves
  the regex floor deliberately (`served_by=rules`, neutral indicator) and
  never probes or loads a local LLM for polish. Smart actions unchanged.
- Corpus-backed cleanup rules (mirrored Swift/Python, shared parity
  fixture): punctuation-orphan repair, punctuation-aware filler matching,
  stutter dedup, ellipsis recase exclusion.

### Fixed
- A stability review (four parallel review agents, 23 verified findings,
  all fixed) closed every known silent dictation-loss path: Fn-hold flags
  flicker truncating mid-utterance (release grace window + queued
  re-press), the weak-speech empty-decode retry gate, short confident
  utterances rejected on coverage geometry, cockpit sessions left
  "recording" on a dead engine after a device change, failed cockpit
  chunks vanishing without retention or receipts, paste under secure
  event input reporting success while the text landed nowhere, silent
  long-form auto-save failures (cockpit now warns), Keychain save
  failures leaving the UI claiming a key is configured, corrupt
  providers.json silently wiped (now quarantined aside), the unmessaged
  60 s capture cutoff, and backend crash-restart storms (backoff, a
  persistent cap, and respawns deferred while a capture is in flight).
- Hallucination filter: greetings are short-audio-only (a padded
  "Hello everyone" email opener now inserts) and long-audio thank-you
  outros require pure outro vocabulary, so real sentences like "Thanks
  for listening to my pitch today" pass — Swift and Python in lockstep
  via the shared parity fixture.
- Backend: whisper/VAD model-load failures retry after a 60 s cooldown
  instead of staying dead for the process lifetime; ML inference runs on
  a dedicated 2-worker pool so cancelled requests can't stack orphan
  decodes; readiness probes are TTL-cached and stale readiness
  self-heals after connection-level failures.

### Security
- transformers bumped 5.3.0 → 5.5.0, closing CVE-2026-5241 (arbitrary code
  execution in the LightGlue model-loading path — not reachable as
  configured since VoxFlow never loads LightGlue, but fixed at the source
  anyway). Validated against the real-model STT regression suite: 14/14
  clips, p50 713 ms vs the 5.3.0 baseline's 707 ms measured immediately
  prior.
- transformers bumped 4.56 → 5.3.0 (with huggingface-hub 0.34 → 1.22),
  actually fixing CVE-2026-4372 rather than relying on the dismissed-alert
  mitigations (WhisperKit default, offline mode, official models).
  Validated against the real-model STT regression suite: 14/14 clips pass
  with latency identical to the 4.56 baseline (p50 721 ms).

## [0.1.2] — 2026-07-04

A drift-review and hardening release: a full-repo drift audit, a
production-hardening pass over the privacy and process-management layers,
and an adversarial multi-agent review of the hardening itself (which
reworked one design before it shipped). One user-facing behavior change:
cockpit keyboard shortcuts now respect an active text edit.

### Security
- Privacy consent tokens now bind the raw/redacted choice: the first use of
  a token locks it, so the two-use cleanup token (light + polish review)
  can no longer preview redacted text and then commit the raw original.
- The app-managed backend spawn refuses to bind a non-loopback host at the
  bind point itself (it always requested loopback; now the Python side
  enforces it too, including the bracketed `[::1]` form). Manual runs via
  `scripts/run_backend.sh` are unaffected.
- The backend PID file records which app session spawned the backend, and
  stale cleanup refuses to kill — and leaves the record of — a backend
  spawned by a different session, protecting concurrent sessions from
  reaping each other. Crash recovery is unchanged: leftovers from a crashed
  session are still reaped through the command-line identity gate.

### Fixed
- Cockpit keyboard shortcuts no longer hijack native text editing: while
  the transcript editor (or a search field) has focus, ⌘Z undoes your
  typing and ⌘C copies the selection (both previously acted on the whole
  transcript / last smart action), esc exits editing — committing the
  draft — with a second esc closing, and ⌘↩ commits your draft before
  inserting (previously it inserted the last saved text, silently dropping
  uncommitted edits).
- The Settings test-connection button no longer reports an Ollama model as
  "available" when the model-list probe itself fails (timeout, reset); it
  now says the model could not be verified.
- `OllamaBackend`'s literal default model is the RAM-tier-safe
  `gemma4:e2b-mlx` (was the 9 GB `e4b-mlx`, which thrashes 16 GB machines
  when constructed directly without the tier resolver).
- Smart actions that return empty output can no longer land on the cockpit
  undo stack (they were already excluded from session history).
- Readiness-probe failures log why (once per provider) instead of silently
  degrading, and an Anthropic provider with a key on file always reads as
  reachable in generic availability probes.
- The app bundle's version string now tracks releases (it had stayed at
  0.1.0 through v0.1.1).

### Changed
- Cockpit polish: transient error banner auto-dismisses after 8 s, the
  polish-provenance pill is visible to VoiceOver, and an empty session no
  longer claims "auto-saved".

## [0.1.1] — 2026-07-01

A stability and hardening release: three weeks of daily-driver use, an
adversarial multi-agent review, and field diagnostics via the JSONL audit
receipts drove ~55 commits of fixes. No new user-facing surfaces.

### Changed
- Dictation polish now runs through the local Gemma LLM (via Ollama) on the
  default WhisperKit path instead of the deterministic regex pipeline. The
  regex pipeline remains the fallback whenever the backend is still warming up
  or unreachable, so dictation never hard-depends on Ollama. Auto-insert
  resolves only the mode it actually inserts (one backend call instead of two),
  so text lands faster.
- Chrome's default per-app profile is now light cleanup (was raw insertion):
  rules-based tidying with no model load. Full Gemma polish stays opt-in per
  app — keeping the ~6 GB polish model resident starves live capture on 16 GB
  machines when dictating into the browser.
- The backend stays warm based on your global insert behavior rather than the
  app you happen to be focused on, so the local model is ready regardless of
  focus.
- Ollama `keep_alive` default is now 15 minutes (was 24 h): the polish model
  stays warm through an active session and frees ~6 GB between sessions.
  Override with `VOXFLOW_OLLAMA_KEEP_ALIVE=24h` on RAM-rich machines.
- Distribution is now explicitly fork-and-build: the DMG/notarization path was
  removed, and ad-hoc signing requires a loud `VOXFLOW_ALLOW_ADHOC=1` opt-in
  (a free-tier Apple Development certificate remains the recommended way to
  keep the Accessibility grant across rebuilds).

### Added
- Capture stall watchdog: if the audio engine starts but the input device
  never delivers a buffer, the capture stops within 3 s with a clear status
  line (and a `capture_stalled` audit receipt) instead of hanging silently.
- Audit receipts now record full provenance (which provider and model actually
  served each insertion, in auto-insert and review mode) plus capture
  diagnostics: first-buffer latency, applied gain, idle gap, leading silence.
- Weak-microphone feedback: empty captures with sub-speech input level show
  "very low mic level — check your input" instead of a generic "no speech
  detected".
- CI: non-blocking Ruff lint job, Dependabot for GitHub Actions, and all
  workflow actions pinned to commit SHAs.

### Fixed
- Front-clipped and empty captures (the dominant field failure): the "speak
  now" cue is now gated on the first real audio buffer instead of engine
  start (~150 ms early), in both quick dictation and the cockpit; weak audio
  gets decoder-side gain normalization and a one-shot decode retry; a
  generation guard keeps stale audio-tap callbacks from leaking old audio or
  firing the cue for a finished capture.
- Successive dictations pasted into AX-opaque apps (Electron, web areas,
  terminals) ran together without spaces; the new boundary fallback was then
  hardened so it cannot misfire: cursor-at-field-start is honored as
  authoritative, and the remembered boundary is invalidated by any real
  keystroke or click, by undo, by a 60 s age bound, and under secure input.
- A cancelled or superseded dictation can no longer insert stale text: every
  auto-insert path gates on a final cancellation check, and cancellation is
  handled quietly instead of surfacing a backend-failure banner.
- Backend lifecycle: spawns at cold launch (not after the WhisperKit load),
  honors a custom `VOXFLOW_BACKEND_URL` end-to-end including stale-listener
  cleanup, never SIGTERMs a process on the port or in the PID file without
  confirming it is actually a VoxFlow backend, and no longer churns readiness
  on no-op reconfigurations.
- Assistant handoff (experimental): lifecycle hardening (cancel, escalate,
  bound, replace) and a pipe-buffer deadlock fix for large transcripts.
- Smart actions surface a provider-unavailable error instead of silently
  swallowing it; tone changes degrade to local cleanup when the backend
  fails.

### Security
- Cloud STT fallback is off by default (raw audio cannot be PII-redacted);
  privacy documentation narrowed to exactly what is enforced.
- Cleanup consent tokens are bound to the exact consented payload, not just
  the session and operation.
- Email-redaction regex hardened against quadratic-blowup (ReDoS) inputs.
- Dependency bump: sentencepiece 0.2.0 → 0.2.1 (GHSA-38vq-g6vr-w8wf).

## [0.1.0] — 2026-06-14

First public release. VoxFlow Local is distributed as source you build
yourself — no prebuilt binary or notarized installer by design (see the
README's "Building from source"). Highlights of what ships:

### Dictation core
- Hold-to-talk dictation (Fn by default, configurable) with WhisperKit
  on-device STT (CoreML / Neural Engine, zero network) and target-aware
  accessibility insertion with clipboard-paste fallback and smart spacing.
- Cleanup modes (Raw / Light / Polish) with tone controls (Neutral, Concise,
  Formal, Friendly) and per-app profiles.
- Polish via a local LLM through Ollama (Gemma 4, RAM-tiered model
  selection) with a deterministic regex pipeline as the always-available
  fallback.
- Two-tier Whisper hallucination filtering (Swift and Python kept in parity
  by a shared 51-case fixture), an audio energy gate, and a transcript gate
  at every insertion ingress. Every insertion and every gate rejection
  writes a JSONL audit receipt to `~/Library/Logs/VoxFlow/insertions.jsonl`.

### Cockpit (long-form workspace)
- ⌥⌘V workspace for long-form capture with live chunked transcription,
  editable review, smart actions (memo, MECE, action items, steel-man,
  pyramid, disclaimer) with undo history, voice commands in review, and
  workflow chains runnable from the ⌘K palette.
- Personal dictionary that biases WhisperKit recognition and learns
  corrections from review edits; voice snippets with per-context expansion.

### Bring your own model (BYOM)
- Per-task provider chains (polish, smart actions) over Ollama,
  OpenAI-compatible servers (LM Studio, llama.cpp, vLLM, mlx_lm.server),
  OpenAI, and Anthropic. Availability failures fall through the chain;
  the regex floor is unconditional. API keys live in the macOS Keychain.
- Mode-in-use indicator surfaces which provider/model actually served a
  request, including the degraded regex-fallback state.

### Privacy
- Local-first by default. Cloud providers are opt-in and off by default;
  cloud-bound text is PII-redacted (Luhn-validated) before it leaves the
  machine. The private-API mode adds an explicit per-request payload preview
  and bounded-use consent tokens. Cloud STT fallback is off unless opted in
  (raw audio cannot be redacted).

### Experimental (off by default)
- Assistant handoff: pipe a transcript to a user-configured CLI with a
  mandatory payload preview; never auto-executes.
- Protocol commands: voice-triggered workflow chains behind a strict
  full-utterance grammar and confidence floor.
- EN→DE translation and meeting-notes modes.
