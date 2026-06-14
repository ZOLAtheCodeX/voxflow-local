# Changelog

All notable changes to VoxFlow Local are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/) once past 1.0.

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
