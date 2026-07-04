# Changelog

All notable changes to VoxFlow Local are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) once past 1.0.

## [Unreleased]

### Fixed
- Editing the transcript in the cockpit review pane no longer fights the
  global shortcuts: while the editor (or a search field) has focus, ⌘Z
  undoes your typing and ⌘C copies the selection (both previously acted on
  the whole transcript / last smart action), and esc exits editing —
  committing the draft — instead of closing the window. A second esc closes.
- The Settings test-connection button no longer reports an Ollama model as
  "available" when the model-list probe itself fails (timeout, reset); it
  now says the model could not be verified.
- `OllamaBackend`'s literal default model is the RAM-tier-safe
  `gemma4:e2b-mlx` (was the 9 GB `e4b-mlx`, which thrashes 16 GB machines
  when constructed directly without the tier resolver).
- Smart actions that return empty output can no longer land on the cockpit
  undo stack (they were already excluded from session history).

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
