# Extended Dictation Fix — Design Document

**Date:** 2026-02-22
**Priority:** 3 (from next-session roadmap)
**Approach:** B — Chunking + Progress

## Problem

Dictation produces truncated text after ~10 seconds. Target duration is 30-45 seconds of continuous speech. Two root causes:

1. **No chunking in HuggingFace pipelines** — Both `VoxtralEngine` and `WhisperEngine` create `pipeline("automatic-speech-recognition", ...)` without `chunk_length_s`, so the model processes audio as a single forward pass. Long audio exceeds the model's context window and gets silently truncated.

2. **HTTP timeout too short** — `BackendAPIClient` sets `timeoutIntervalForRequest = 30` seconds. Chunked transcription of 30-45s audio can take 10-20s on local models, leaving no headroom for slower hardware or concurrent load.

## Design

### Section 1: Pipeline Chunking (Backend)

Add sliding-window chunking to both STT engines in `backend/app/server.py`:

**VoxtralEngine._load_pipeline()** (line ~233):
```python
self._pipe = pipeline(
    "automatic-speech-recognition",
    model=model_id,
    device=self._device,
    chunk_length_s=30,
    stride_length_s=[5, 1],
)
```

**WhisperEngine._load_pipeline()** (line ~309):
```python
self._pipe = pipeline(
    "automatic-speech-recognition",
    model=model_id,
    device=self._device,
    chunk_length_s=30,
    stride_length_s=[5, 1],
)
```

**Both transcribe() calls** (lines ~262, ~334):
```python
result = self._pipe(audio_array, return_timestamps=True)
```

- `chunk_length_s=30` — each chunk is 30 seconds of audio
- `stride_length_s=[5, 1]` — 5s left overlap + 1s right overlap for smooth joins
- `return_timestamps=True` — required for the chunking algorithm to merge segments

Short clips (<30s) pass through unchanged — chunking is a superset.

### Section 2: HTTP Timeout (Frontend)

Bump `timeoutIntervalForRequest` from `30` to `120` in `Sources/VoxFlowApp/Services/BackendAPIClient.swift` (line ~82).

120 seconds provides 4× headroom over expected chunked transcription latency (10-20s for 30-45s audio on local models).

### Section 3: Progress Feedback UI (Frontend)

Add an elapsed-time counter to the command palette during transcription:

1. When `sessionState` transitions to `.processing`, start a `Timer.publish(every: 1.0)` that updates an elapsed counter ("Processing... 3s")
2. Display the counter below the status text in the palette view
3. When `sessionState` leaves `.processing`, stop the timer and reset
4. If elapsed exceeds 90 seconds, show "Taking longer than expected..." as a soft warning (no auto-cancel)

**Backend addition:** Add `processing_time_ms` field to the `/v1/transcribe` JSON response.

### Section 4: Testing

**Backend (Python):**
- Unit test: `VoxtralEngine` pipeline created with `chunk_length_s=30` and `stride_length_s`
- Unit test: `WhisperEngine` pipeline created with matching chunking params
- Unit test: transcribe response includes `processing_time_ms` field
- Regression: existing golden clips still pass with chunking enabled

**Frontend (Swift):**
- Unit test: elapsed timer starts when `sessionState` enters `.processing`, stops when it leaves
- Unit test: warning text appears after 90s threshold

**Manual smoke test:**
- Record ~30s of continuous speech — verify full text returned (not truncated)
- Record ~5s — verify short clips still work normally
- Watch palette during processing — confirm elapsed counter ticks

## Files Touched

| File | Change |
|------|--------|
| `backend/app/server.py` | Add chunking params to both pipelines, `return_timestamps=True`, `processing_time_ms` in response |
| `Sources/VoxFlowApp/Services/BackendAPIClient.swift` | Bump timeout 30 → 120 |
| `Sources/VoxFlowApp/Views/CommandPaletteView.swift` | Add elapsed timer + display |
| `backend/tests/test_server.py` | Chunking + timing tests |
| `Tests/VoxFlowAppTests/` | Elapsed timer tests |
