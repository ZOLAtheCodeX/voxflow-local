# Synthetic dictation fixtures

Generated locally with macOS `say`, the Samantha voice, and 16 kHz signed
16-bit PCM WAV output. These contain no microphone recordings or personal data.

| File | Spoken text |
|---|---|
| yes.wav | Yes. |
| tomorrow.wav | Tomorrow. |
| approved.wav | Approved. |
| sentence.wav | Please move the team meeting to tomorrow morning. |
| quiet_sentence.wav | The sentence fixture with every PCM sample multiplied by 0.12. |
| passage.wav | The team reviewed the project schedule this morning. We agreed to finish the first draft by Friday and send it for review next week. Please include the updated figures and explain the remaining questions in a short note. |

To generate a spoken fixture:

```bash
say -v Samantha -o yes.wav --data-format=LEI16@16000 'Yes.'
```

The three short words reproduce the decoder window-padding regression. The
remaining fixtures measure normal, quiet, and longer speech. Silence and noise
controls live in `backend/tests/fixtures/golden_clips`.
