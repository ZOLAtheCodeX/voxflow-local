# Voice control reference

VoxFlow's voice control is **in-app**: it switches modes, tones, and
windows, and runs your workflow chains. It does not execute shell
commands or control other applications.

## Voice-control lane

Hold the command hotkey (default `Fn⌘Space`), speak, release. The badge
shows **VOICE CONTROL** while active.

| Say | Effect |
|---|---|
| "dictation mode" / "normal mode" | switch to dictation |
| "meeting mode" / "translate mode" / "prompt mode" | switch workflow |
| "local mode" / "private api" | switch provider |
| "whisper stt" / "openai stt" | switch STT backend |
| "tone formal" (concise / friendly / neutral) | set tone |
| "approve" / "insert" / "copy" / "retry" / "undo" | review actions |
| "open cockpit" / "open dashboard" | open windows |
| "benchmark" | run the translation benchmark |

## Protocol commands (experimental, off by default)

Enable in Settings ▸ Advanced ▸ Workflow. Then:

> "run *[name]* protocol" — also "start" or "execute", optional "the"

runs the workflow chain with that name (the same chains you manage in
Settings ▸ Dictation Tools and the cockpit ⌘K palette). Works in the
voice-control lane and in cockpit review.

Safety by design: the **entire utterance** must match the trigger
grammar; low-confidence transcriptions never fire; the feature is
disabled until you opt in. Chains can capture, run smart actions,
insert, switch mode/tone (`setMode`, `setTone`), and open windows
(`openWindow`).

Example "focus protocol": `setMode: meeting` → `openWindow: cockpit`.
