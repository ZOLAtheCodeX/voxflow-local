# NLP-Lite Cleanup Engine — Design

> Swift-native text cleanup using Apple NaturalLanguage framework.
> Replaces Python backend dependency for cleanup when using WhisperKit STT.

## Problem

FLAN-T5-Small (60M params) echoes input unchanged — Polish mode is effectively Light mode
with extra latency. Both Light and Polish require the Python backend even when WhisperKit
handles STT natively. The rule-based cleanup (`light_cleanup`, `apply_tone`) is too minimal:
only strips 4 filler patterns, and tone transforms are cosmetic.

## Solution

A new `TextCleanupService` in Swift that runs a 7-step NLP-lite pipeline using Apple's
built-in `NaturalLanguage` framework. When `STTBackend == .whisperKit`, the entire dictation
path (STT + cleanup) runs in-process with zero network and zero Python.

## Architecture

```
Raw audio → WhisperKit STT → TextCleanupService → Insert
                                  │
                    ┌─────────────┴──────────────┐
                    │  1. Normalize whitespace    │
                    │  2. Spoken punctuation      │
                    │  3. Repeated word removal   │
                    │  4. NLTokenizer sent split  │
                    │  5. NLTagger filler detect  │
                    │  6. Sentence recasing       │
                    │  7. Tone transform          │
                    └────────────────────────────┘
```

### CleanupMode Mapping

| Mode   | Steps  | Description                                    |
|--------|--------|------------------------------------------------|
| Raw    | 1-2    | Whitespace normalization + spoken punctuation   |
| Light  | 1-6    | Full cleanup without tone transform             |
| Polish | 1-7    | Full pipeline including tone transform          |

## Pipeline Steps

### Step 1: Normalize Whitespace
Collapse multiple spaces/newlines to single space, trim leading/trailing.

### Step 2: Spoken Punctuation
Convert dictated punctuation words to symbols. Context-aware matching at clause
boundaries only.

| Spoken                              | Output |
|-------------------------------------|--------|
| "period" / "full stop"              | `.`    |
| "comma"                             | `,`    |
| "question mark"                     | `?`    |
| "exclamation point/mark"            | `!`    |
| "colon"                             | `:`    |
| "semicolon"                         | `;`    |
| "new line" / "newline"              | `\n`   |
| "new paragraph"                     | `\n\n` |
| "open quote" / "close quote"        | `"`    |
| "dash" / "hyphen"                   | `—`/`-`|

### Step 3: Repeated Word Removal
Deduplicate consecutive identical words: "I want to to go" → "I want to go".
Only exact adjacent duplicates.

### Step 4: NLTokenizer Sentence Splitting
Use `NLTokenizer(unit: .sentence)` for proper sentence boundary detection.
Handles abbreviations (Dr., U.S.), decimal numbers, and edge cases that regex
cannot handle reliably.

### Step 5: NLTagger Filler Detection
Use `NLTagger(tagSchemes: [.lexicalClass])` with two-pass approach:

**Pass 1 (deterministic):** Remove always-filler words regardless of POS tag.
List: `um, uh, er, ah, hmm`

**Pass 2 (POS-aware):** For ambiguous words, check POS tag and position:
- Words: `like, so, right, actually, basically, literally, you know, I mean,
  kind of, sort of, anyway`
- Remove if tagged as interjection/adverb at clause boundary or sentence start
- Keep if tagged as verb/adjective/noun in a content role

Example: "I like, like, really like dogs" → "I really like dogs"

### Step 6: Sentence Recasing
Capitalize first character of each sentence after split. Preserve existing
capitalization within sentences (proper nouns, acronyms).

### Step 7: Tone Transform

| Tone     | Rules                                                                  |
|----------|------------------------------------------------------------------------|
| Neutral  | No transform (steps 1-6 output as-is)                                 |
| Concise  | Strip hedging ("I think maybe", "it seems like", "in my opinion"),    |
|          | merge short sentences (<5 words) with adjacent via comma,              |
|          | remove softeners ("just", "really", "very", "quite", "a bit")         |
| Formal   | Expand contractions ("don't" → "do not", "can't" → "cannot"),         |
|          | remove casual interjections ("okay so", "alright", "hey"),             |
|          | ensure trailing period                                                 |
| Friendly | Keep contractions, soften imperatives ("Do X" → "Let's do X" when     |
|          | sentence starts with bare verb), preserve exclamation marks            |

## Integration

### WhisperKit Path (in-process, no backend)
When `sttBackend == .whisperKit`:
- `processDictation` calls `TextCleanupService.cleanup(rawText, mode:, tone:)` directly
- No `BackendAPIClient.cleanup()` call
- `TranscriptCandidate` fields (`rawText`, `lightText`, `polishText`) generated in-process

### Backend Path (unchanged)
When `sttBackend == .voxtral/.whisper/.openai`:
- Existing Python cleanup path unchanged (backend already running for STT)
- `POST /v1/cleanup` stays functional

### Per-App Profiles
`resolveEffectiveProfile()` works identically — routes to Swift cleanup vs Python
cleanup based on STT backend selection.

## What Stays in Python

The Python backend is NOT removed. Still needed for:
- Translation (EN→DE)
- Meeting mode (summarization, speaker segmentation)
- STT via Voxtral/Whisper backends
- Private API mode cleanup

## Testing

- Unit tests per pipeline step (filler detection, spoken punctuation, tone, dedup)
- Integration tests with dictation-like input strings
- Golden input/output regression pairs
- Latency benchmark target: <10ms for typical dictation length

## Non-Goals

- No model inference (no FLAN-T5, no local LLM)
- No API calls for cleanup
- No removal of Python backend (still needed for other features)
- No semantic deduplication or paraphrasing
