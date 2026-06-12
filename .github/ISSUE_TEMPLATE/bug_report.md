---
name: Bug report
about: Something misbehaves
labels: bug
---

**What happened**

**What you expected**

**Steps to reproduce**

1.

**Environment**

- macOS version:
- Mac model / RAM:
- VoxFlow version or commit:
- STT backend (WhisperKit / Whisper / OpenAI):
- Polish provider (Ollama model, or BYOM provider kind):

**Diagnostics**

- Output of `./scripts/doctor.sh` if relevant.
- For phantom or wrong insertions: the matching lines from
  `~/Library/Logs/VoxFlow/insertions.jsonl` (every insertion and every
  rejected transcript writes a receipt there — redact the text if private).
- Backend state if relevant: `curl http://127.0.0.1:8765/v1/ready`
