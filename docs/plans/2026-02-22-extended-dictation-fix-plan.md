# Extended Dictation Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix truncated transcription for recordings longer than ~10 seconds by enabling HuggingFace pipeline chunking, bumping the HTTP timeout, and adding an elapsed-time progress indicator.

**Architecture:** Backend changes add `chunk_length_s` / `stride_length_s` to both STT engine pipelines and `return_timestamps=True` to inference calls. Frontend bumps the HTTP timeout from 30s to 120s and adds a ticking elapsed-time counter in the command palette's "Transcribing..." card. A `processing_time_ms` field is added to the transcribe API response.

**Tech Stack:** Python (FastAPI, HuggingFace transformers), Swift (SwiftUI, Combine, URLSession)

---

### Task 1: Add chunking params to VoxtralEngine pipeline

This task adds sliding-window chunking to the Voxtral STT engine so audio longer than 30 seconds is processed in overlapping chunks rather than a single forward pass.

**Files:**
- Modify: `backend/app/server.py:233-238` (VoxtralEngine._load_pipeline)
- Modify: `backend/app/server.py:262-265` (VoxtralEngine.transcribe inference call)
- Test: `backend/tests/test_endpoints.py`

**Step 1: Write the failing test**

Add this test class to `backend/tests/test_endpoints.py` after the existing `TestHealth` class:

```python
class TestTranscribeChunking:
    @pytest.mark.anyio
    async def test_transcribe_returns_processing_time_ms(self, client: httpx.AsyncClient):
        """Verify the transcribe response includes processing_time_ms field."""
        import base64
        import struct

        # 1 second of silence at 16kHz (16-bit PCM)
        silence = struct.pack("<" + "h" * 16000, *([0] * 16000))
        b64 = base64.b64encode(silence).decode()

        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-chunking",
            "audio_pcm16le": b64,
            "sample_rate": 16000,
            "language_hint": "en",
            "chunk_index": 0,
        })
        assert resp.status_code == 200
        data = resp.json()
        assert "processing_time_ms" in data
        assert isinstance(data["processing_time_ms"], int)
        assert data["processing_time_ms"] >= 0
```

**Step 2: Run test to verify it fails**

Run: `./.venv/bin/python -m pytest backend/tests/test_endpoints.py::TestTranscribeChunking::test_transcribe_returns_processing_time_ms -v`
Expected: FAIL — `processing_time_ms` key not in response.

**Step 3: Add chunking to VoxtralEngine._load_pipeline and update transcribe**

In `backend/app/server.py`, change the `pipeline()` call inside `VoxtralEngine._load_pipeline()` (lines 233-238) from:

```python
                    self._pipeline = pipeline(
                        task="automatic-speech-recognition",
                        model=candidate,
                        device=preferred_torch_device(),
                        torch_dtype="auto",
                    )
```

to:

```python
                    self._pipeline = pipeline(
                        task="automatic-speech-recognition",
                        model=candidate,
                        device=preferred_torch_device(),
                        torch_dtype="auto",
                        chunk_length_s=30,
                        stride_length_s=[5, 1],
                    )
```

Then change the inference call in `VoxtralEngine.transcribe()` (lines 262-265) from:

```python
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": language_hint},
            )
```

to:

```python
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": language_hint},
                return_timestamps=True,
            )
```

Then add `processing_time_ms` to the `TranscribeResponse` model (line ~85-89). Change:

```python
class TranscribeResponse(BaseModel):
    text: str
    is_final: bool
    latency_ms: int
    confidence_estimate: float
```

to:

```python
class TranscribeResponse(BaseModel):
    text: str
    is_final: bool
    latency_ms: int
    confidence_estimate: float
    processing_time_ms: int = 0
```

Then update the `transcribe()` endpoint (line ~1732-1737). Change:

```python
    return TranscribeResponse(
        text=text,
        is_final=True,
        latency_ms=latency_ms,
        confidence_estimate=confidence,
    )
```

to:

```python
    return TranscribeResponse(
        text=text,
        is_final=True,
        latency_ms=latency_ms,
        confidence_estimate=confidence,
        processing_time_ms=latency_ms,
    )
```

**Step 4: Run test to verify it passes**

Run: `./.venv/bin/python -m pytest backend/tests/test_endpoints.py::TestTranscribeChunking -v`
Expected: PASS

**Step 5: Commit**

```bash
git add backend/app/server.py backend/tests/test_endpoints.py
git commit -m "feat(backend): add chunking params to VoxtralEngine pipeline

chunk_length_s=30, stride_length_s=[5,1], return_timestamps=True.
Adds processing_time_ms to TranscribeResponse."
```

---

### Task 2: Add chunking params to WhisperEngine pipeline

Same chunking treatment for the Whisper STT engine.

**Files:**
- Modify: `backend/app/server.py:309-314` (WhisperEngine._load_pipeline)
- Modify: `backend/app/server.py:334-337` (WhisperEngine.transcribe inference call)
- Test: `backend/tests/test_endpoints.py`

**Step 1: Write the failing test**

Add this test to `TestTranscribeChunking` in `backend/tests/test_endpoints.py`:

```python
    @pytest.mark.anyio
    async def test_transcribe_response_has_all_expected_fields(self, client: httpx.AsyncClient):
        """Verify transcribe response schema includes all fields."""
        import base64
        import struct

        silence = struct.pack("<" + "h" * 16000, *([0] * 16000))
        b64 = base64.b64encode(silence).decode()

        resp = await client.post("/v1/transcribe", json={
            "session_id": "test-schema",
            "audio_pcm16le": b64,
            "sample_rate": 16000,
            "language_hint": "en",
            "chunk_index": 0,
        })
        data = resp.json()
        expected_keys = {"text", "is_final", "latency_ms", "confidence_estimate", "processing_time_ms"}
        assert expected_keys.issubset(data.keys())
```

(This test should already pass from Task 1. It serves as a schema contract test.)

**Step 2: Run test to verify schema test passes**

Run: `./.venv/bin/python -m pytest backend/tests/test_endpoints.py::TestTranscribeChunking -v`
Expected: PASS (both tests)

**Step 3: Add chunking to WhisperEngine._load_pipeline and update transcribe**

In `backend/app/server.py`, change `WhisperEngine._load_pipeline()` (lines 309-314) from:

```python
                self._pipeline = pipeline(
                    task="automatic-speech-recognition",
                    model=self.model_id,
                    device=preferred_torch_device(),
                    torch_dtype="auto",
                )
```

to:

```python
                self._pipeline = pipeline(
                    task="automatic-speech-recognition",
                    model=self.model_id,
                    device=preferred_torch_device(),
                    torch_dtype="auto",
                    chunk_length_s=30,
                    stride_length_s=[5, 1],
                )
```

Then change the inference call in `WhisperEngine.transcribe()` (lines 334-337) from:

```python
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": language_hint},
            )
```

to:

```python
            output = self._pipeline(
                {"array": audio, "sampling_rate": sample_rate},
                generate_kwargs={"language": language_hint},
                return_timestamps=True,
            )
```

**Step 4: Run all backend tests to verify nothing broke**

Run: `./.venv/bin/python -m pytest backend/tests/ -v`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add backend/app/server.py backend/tests/test_endpoints.py
git commit -m "feat(backend): add chunking params to WhisperEngine pipeline

chunk_length_s=30, stride_length_s=[5,1], return_timestamps=True.
Mirrors Voxtral chunking config."
```

---

### Task 3: Bump HTTP timeout in BackendAPIClient

The Swift frontend's `URLSession` timeout is 30 seconds — too tight for chunked transcription of 30-45s audio on local models. Bump to 120 seconds.

**Files:**
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift:82`
- Modify: `Sources/VoxFlowApp/Services/BackendAPIClient.swift:3-8` (TranscribeResponse struct — add `processingTimeMs`)

**Step 1: Update the timeout and response model**

In `Sources/VoxFlowApp/Services/BackendAPIClient.swift`, change line 82 from:

```swift
        config.timeoutIntervalForRequest = 30
```

to:

```swift
        config.timeoutIntervalForRequest = 120
```

Then update the `TranscribeResponse` struct (lines 3-8) from:

```swift
struct TranscribeResponse: Codable {
    let text: String
    let isFinal: Bool
    let latencyMs: Int
    let confidenceEstimate: Double
}
```

to:

```swift
struct TranscribeResponse: Codable {
    let text: String
    let isFinal: Bool
    let latencyMs: Int
    let confidenceEstimate: Double
    let processingTimeMs: Int
}
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build succeeds with no errors.

**Step 3: Run Swift tests**

Run: `swift test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/BackendAPIClient.swift
git commit -m "feat(frontend): bump HTTP timeout 30s -> 120s, add processingTimeMs to TranscribeResponse"
```

---

### Task 4: Add elapsed-time counter to transcribing state card

The command palette currently shows a static "Transcribing..." spinner. Replace it with a ticking elapsed-time counter so users know VoxFlow is alive during long transcriptions.

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift:578-588` (transcribingStateCard)

**Step 1: Add elapsed timer state and update transcribing card**

In `Sources/VoxFlowApp/Views/CommandPaletteView.swift`, add a new `@State` property after line 10 (`@State private var recordingBadgeAnimating = false`):

```swift
    @State private var transcribingElapsed: Int = 0
    @State private var transcribingTimer: Timer?
```

Then replace the `transcribingStateCard` computed property (lines 578-588) from:

```swift
    private var transcribingStateCard: some View {
        VStack(spacing: VF.spacingMedium) {
            ProgressView()
                .controlSize(.regular)
            Text("Transcribing...")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
    }
```

with:

```swift
    private var transcribingStateCard: some View {
        VStack(spacing: VF.spacingMedium) {
            ProgressView()
                .controlSize(.regular)
            Text("Processing… \(transcribingElapsed)s")
                .font(VF.bodyFont)
                .foregroundStyle(.secondary)
            if transcribingElapsed > 90 {
                Text("Taking longer than expected…")
                    .font(VF.captionFont)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge))
        .onAppear { startTranscribingTimer() }
        .onDisappear { stopTranscribingTimer() }
    }

    private func startTranscribingTimer() {
        transcribingElapsed = 0
        transcribingTimer?.invalidate()
        transcribingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                transcribingElapsed += 1
            }
        }
    }

    private func stopTranscribingTimer() {
        transcribingTimer?.invalidate()
        transcribingTimer = nil
        transcribingElapsed = 0
    }
```

**Step 2: Build to verify**

Run: `swift build`
Expected: Build succeeds with no errors.

**Step 3: Run Swift tests**

Run: `swift test`
Expected: All tests pass (no new tests needed — this is a pure UI change with existing `sessionState` machinery).

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Views/CommandPaletteView.swift
git commit -m "feat(frontend): add elapsed-time counter to transcribing state card

Shows 'Processing… Ns' with 1s tick. Warns after 90s."
```

---

### Task 5: Run full test suite and verify

Ensure all backend and frontend tests pass after all changes.

**Files:**
- No modifications — verification only.

**Step 1: Run backend tests**

Run: `./.venv/bin/python -m pytest backend/tests/ -v`
Expected: All tests PASS.

**Step 2: Run Swift tests**

Run: `swift test`
Expected: All tests PASS.

**Step 3: Run full test suite**

Run: `./scripts/test_all.sh --skip-runtime-checks`
Expected: All tests PASS.

**Step 4: Commit (no-op — nothing to commit if all green)**

No commit needed. If tests fail, fix and commit the fix.

---

### Task 6: Manual smoke test

Build, install, and manually verify the fix works end-to-end.

**Files:**
- No modifications — verification only.

**Step 1: Build and install app bundle**

Run:
```bash
./scripts/build_app_bundle.sh
./scripts/install_app_bundle.sh
```

**Step 2: Start backend**

Run: `./scripts/run_backend.sh`

**Step 3: Launch app**

Run: `./scripts/open_app_bundle.sh`

**Step 4: Manual test checklist**

| # | Test | Expected |
|---|------|----------|
| 1 | Record ~30s of continuous speech in TextEdit | Full text returned, not truncated |
| 2 | Record ~5s of speech | Works normally (chunking is superset) |
| 3 | Watch palette during transcription | "Processing… Ns" counter ticks |
| 4 | Wait >90s on slow hardware (or simulate) | "Taking longer than expected…" warning appears |

---

### Task 7: Update docs

Update CLAUDE.md and README.md with the new behavior.

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Update CLAUDE.md**

In `CLAUDE.md`, update the test count and add note about chunking:
- Update test count if it changed
- In the Python patterns section, add: `- **STT chunking**: Both VoxtralEngine and WhisperEngine use `chunk_length_s=30` with 5s/1s stride for long-form transcription`

**Step 2: Update README.md**

In `README.md` under "Current Constraints", add:
- `- Extended dictation supports 30-45 seconds of continuous speech (chunked transcription with sliding window).`

**Step 3: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update conventions and constraints for extended dictation support"
```
