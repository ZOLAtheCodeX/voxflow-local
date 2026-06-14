# VoxFlow Local

[![CI](https://github.com/ZOLAtheCodeX/voxflow-local/actions/workflows/ci.yml/badge.svg)](https://github.com/ZOLAtheCodeX/voxflow-local/actions/workflows/ci.yml)

Local-first dictation for macOS. Hold a key, speak, release: your words land
in whatever app has focus, cleaned up and optionally polished by a local LLM.
Speech never leaves your Mac unless you explicitly configure and approve a
cloud provider.

- **On-device speech-to-text** via WhisperKit (CoreML, Apple Neural Engine,
  zero network).
- **Text polish** via a local LLM through [Ollama](https://ollama.com)
  (Gemma 4), with a deterministic regex cleanup as the always-available
  fallback. Or bring your own model: LM Studio, llama.cpp, vLLM, OpenAI,
  Anthropic.
- **The cockpit** (⌥⌘V): a long-form workspace with live transcription,
  editable review, smart actions (memo, action items, MECE, steel-man,
  pyramid, disclaimer), voice commands, a personal dictionary that biases
  recognition toward your vocabulary, and reusable workflow chains.
- **Privacy by architecture**: cloud calls sit behind an explicit consent
  gate with payload preview and PII redaction; API keys live in the macOS
  Keychain; every insertion writes an audit receipt to
  `~/Library/Logs/VoxFlow/insertions.jsonl`.

## Requirements

| | Minimum | Notes |
|---|---|---|
| macOS | 14 (Sonoma) | Apple Silicon recommended (Neural Engine STT) |
| Xcode / Swift | Swift 6.2 toolchain | you build it yourself (see below) |
| Python | 3.11+ | backend service on 127.0.0.1:8765 |
| Disk for models | ~1 GB minimum | Whisper-Small STT |
| RAM | 8 GB | see the model matrix below |

### Honest model-size callout

The base dictation experience needs only the WhisperKit Whisper-Small model
(about 1 GB, fetched once by a script below). Everything else is optional
and tiered:

| Feature | Model | Size | Needs |
|---|---|---|---|
| Dictation (STT) | WhisperKit Whisper-Small | ~1 GB | any supported Mac |
| Polish + smart actions | `gemma4:e2b-mlx` via Ollama | ~7 GB | 8-24 GB RAM |
| Polish, higher quality | `gemma4:e4b-mlx` via Ollama | ~10 GB | 24 GB+ RAM (it thrashes 16 GB machines; the app auto-selects the right tier) |
| EN→DE translation (experimental) | TranslateGemma 4B/12B or Marian | 1-24 GB | optional |

Without Ollama, polish silently degrades to the regex cleanup pipeline; the
app's mode indicator shows which engine actually served each request.

## Quickstart (60 seconds of typing, plus downloads)

```bash
git clone https://github.com/ZOLAtheCodeX/voxflow-local.git
cd voxflow-local

./scripts/bootstrap_all.sh                  # venv + deps + first Swift build
./scripts/download_whisperkit_model.sh      # ~1 GB STT model
./scripts/reinstall_and_launch.sh           # build, sign, install, launch
# No Apple ID? Prefix the line above with VOXFLOW_ALLOW_ADHOC=1
# (see "Building from source" for the trade-off).

# Optional, for LLM polish:
ollama serve &
ollama pull gemma4:e2b-mlx
```

Grant the two permissions the setup wizard asks for (microphone and
accessibility), hold **Fn**, speak, release. The floating pill shows
recording state; text inserts into the focused app.

> **Always launch the installed bundle** (`open ~/Applications/VoxFlow.app`
> or the reinstall script). Running the raw binary (`swift run`) registers a
> different TCC identity and your Accessibility grant will not stick.

`./scripts/doctor.sh` diagnoses the usual environment problems.

## Building from source — the distribution model

VoxFlow Local is not distributed as a prebuilt binary. There is no download,
no DMG, no notarized installer. You clone the repo and build it yourself, on
your own machine, signed under your own identity. Fork it, change it, run
your own version — that is the intended way to use this project.

The one wrinkle is macOS Accessibility, which VoxFlow needs to type into
other apps. macOS ties the Accessibility grant to the app's code signature,
so how you sign determines whether that grant survives a rebuild:

| Signing | How | Accessibility grant | Cost |
|---|---|---|---|
| **Apple Development cert** (recommended) | Sign in to Xcode with any Apple ID (Settings → Accounts). The free personal team gives you an "Apple Development" certificate the build auto-detects. | Persists across rebuilds | **Free** — no paid Developer Program needed |
| **Ad-hoc** | Re-run the build/install with `VOXFLOW_ALLOW_ADHOC=1` | Resets on every rebuild (you re-approve in System Settings each time) | Free, no Apple account at all |

The build refuses to ad-hoc sign *silently* — that quietly-resetting grant
caused real debugging pain, so ad-hoc is opt-in and loud. Set
`VOXFLOW_SIGN_IDENTITY` to pin a specific identity. A paid Apple Developer
Program membership is **not** required for any of this; it would only matter
if you wanted to notarize a build for distribution to other people's Macs,
which this project intentionally does not do.

## Bring your own model

Polish and smart actions resolve through per-task provider chains configured
in Settings → Models:

| Provider kind | Examples | Payload leaves your Mac? |
|---|---|---|
| `ollama` | Ollama (default) | no |
| `openai_compat` | LM Studio, llama.cpp server, vLLM, mlx_lm.server | no, if local URL |
| `openai` | OpenAI API | yes, behind the consent gate + redaction |
| `anthropic` | Anthropic API | yes, behind the consent gate + redaction |

Chains fall through on provider failure and always bottom out at the local
regex pipeline. API keys are stored in the Keychain and injected into the
backend as environment variables at launch; they never touch a config file.

## The pieces

```
Sources/VoxFlowApp/    SwiftUI menu-bar app: capture, insertion, cockpit, settings
backend/app/           FastAPI service: STT, polish chains, smart actions, privacy
scripts/               bootstrap / run / test / install / release
```

The Swift app talks to the backend on `127.0.0.1:8765` and supervises it
(spawns, health-checks, and replaces stale instances using a per-launch
instance stamp). `voxflow://` URLs automate common actions, e.g.
`open "voxflow://window/cockpit"` or `open "voxflow://backend/start"`.

## Tests

```bash
swift test                                   # Swift suite
./.venv/bin/python -m pytest backend/tests   # Python suite
./scripts/test_all.sh                        # everything incl. STT regression clips
```

Model-dependent tests skip automatically when models or Ollama are absent.

## Contributing, security, license

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
[CHANGELOG.md](CHANGELOG.md). MIT licensed — see [LICENSE](LICENSE).
