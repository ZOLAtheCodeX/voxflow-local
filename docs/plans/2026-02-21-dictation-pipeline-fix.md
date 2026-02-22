# Dictation Pipeline Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix two end-to-end dictation bugs: Notion text insertion failure + incorrect transcription in other apps.

**Architecture:** Four targeted, independent fixes applied in order: (1) reliable paste insertion with app activation + delay, (2) client-side 16kHz audio resampling via AVAudioConverter, (3) default insert behavior changed to raw (skip FLAN-T5), (4) diagnostic logging at every silent guard. Each fix is independently committable.

**Tech Stack:** Swift 6.2, AVFoundation (AVAudioConverter), AppKit (NSRunningApplication, NSPasteboard, CGEvent), Python FastAPI backend

---

### Task 1: Diagnostic Logging in AppCoordinator

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:163-222` (startCapture guards)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:224-300` (finishCaptureAndTranscribe)

**Why first:** Every subsequent fix needs visible diagnostics. Without logging, we can't confirm fixes work.

**Step 1: Add logging at every silent guard in startCapture()**

In `AppCoordinator.swift`, replace the guard block at line 164-166:

```swift
    func startCapture(commandLane: Bool = false) {
        guard state.sessionState == .idle || state.sessionState == .review || state.sessionState == .error || state.sessionState == .onboarding else {
            log.warning("startCapture blocked: sessionState=\(String(describing: state.sessionState))")
            return
        }

        let permissions = permissionService.snapshot()
        if !permissions.microphoneAuthorized {
            log.warning("startCapture blocked: microphone not authorized")
            state.statusLine = "Microphone permission required — grant in System Settings"
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !permissions.accessibilityAuthorized {
            log.warning("startCapture blocked: accessibility not authorized")
            state.statusLine = "Accessibility permission required — grant in System Settings"
            return
        }

        if !state.backendReadyForDictation {
            log.warning("startCapture blocked: backend not ready for dictation")
            state.statusLine = "Backend not ready — wait for model warmup"
            return
        }

        if !commandLane && state.onboardingPhase != .calibrating && !state.canStartCaptureForDictation {
            log.warning("startCapture blocked: no focused text target (focusTarget=\(String(describing: state.focusTarget)))")
            state.statusLine = "Focus a text field or place cursor before dictating"
            return
        }
```

**Step 2: Add logging in finishCaptureAndTranscribe()**

After the transcription result at line 266, add:

```swift
            let rawText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
            log.info("Transcription: '\(rawText.prefix(100))' (confidence=\(transcription.confidenceEstimate), latency=\(transcription.latencyMs)ms)")
```

After text insertion attempts in `processDictation` (around lines 617, 649), the `TextInsertionCoordinator` already records stats. Add logging in `TextInsertionCoordinator.insertText` after the result:

In `TextInsertionCoordinator.swift` line 71, after `let result = insertService.insert(text: text)`:

```swift
        let result = insertService.insert(text: text)
        // Diagnostic: log every insertion attempt
        let log = Logger(subsystem: "local.voxflow.app", category: "TextInsertion")
        log.info("Insert attempt: method=\(String(describing: result.method)), success=\(result.success), fallback=\(result.fallbackUsed), app=\(appName)")
```

Also add same logging in `insertCurrentText()` after line 42.

**Step 3: Build to verify no compile errors**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Services/TextInsertionCoordinator.swift
git commit -m "fix: add diagnostic logging at all pipeline guards and insertion points"
```

---

### Task 2: Reliable Text Insertion (Activate Target App + Paste Delay)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/AccessibilityInsertService.swift:36-46` (insert method)
- Modify: `Sources/VoxFlowApp/Services/AccessibilityInsertService.swift:86-92` (simulatePaste)

**Step 1: Modify `insert()` to capture the target app before attempting insertion**

Replace the `insert(text:)` method (lines 36-46) with:

```swift
    func insert(text: String) -> InsertResult {
        // Capture the target app BEFORE any insertion attempt.
        // During async transcription, focus may have shifted away.
        let targetApp = NSWorkspace.shared.frontmostApplication

        if insertDirectly(text: text) {
            // After AX direct write, copy to clipboard for recoverability
            return InsertResult(method: .accessibilityDirect, success: true, fallbackUsed: false, errorCode: nil)
        }

        if simulatePaste(text: text, targetApp: targetApp) {
            return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        }

        return InsertResult(method: .failed, success: false, fallbackUsed: true, errorCode: "INSERT_FAILED")
    }
```

**Step 2: Rewrite `simulatePaste` to activate target app and add delay**

Replace the `simulatePaste` method (lines 86-92) with:

```swift
    private func simulatePaste(text: String, targetApp: NSRunningApplication? = nil) -> Bool {
        // Save the user's current clipboard so we can restore it after pasting
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }

        // Re-activate the target app — focus may have shifted during transcription
        if let app = targetApp, !app.isActive {
            app.activate()
            // Give macOS time to bring the app window forward
            usleep(150_000) // 150ms
        } else {
            // Small delay even without activation — Electron apps need time
            // to register clipboard changes before Cmd+V arrives
            usleep(50_000) // 50ms
        }

        let pasted = simulateKeyPress(virtualKey: 0x09, flags: .maskCommand)

        // Restore the user's previous clipboard after a brief delay
        // so the target app has time to process the paste event
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let previous = previousContents {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        return pasted
    }
```

**Step 3: Build to verify no compile errors**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/AccessibilityInsertService.swift
git commit -m "fix: activate target app before paste and add timing delay for Electron apps"
```

---

### Task 3: Client-Side Audio Resampling to 16kHz

**Files:**
- Modify: `Sources/VoxFlowApp/Services/AudioCaptureService.swift` (full rewrite of tap callback)

**Step 1: Rewrite AudioCaptureService to resample to 16kHz**

Replace the entire file content with:

```swift
import AVFoundation
import Foundation

struct CapturedAudio {
    let pcm: Data
    let sampleRate: Double
}

enum AudioCaptureError: Error {
    case noInputNode
    case captureNotRunning
    case converterSetupFailed
}

final class AudioCaptureService {
    static let maxBufferBytes = 10 * 1024 * 1024 // ~5 minutes at 16 kHz mono PCM16
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let bufferLock = NSLock()
    private var pcmBuffer = Data()
    private var isCapturing = false
    private var _bufferLimitReached = false

    var bufferLimitReached: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _bufferLimitReached
    }

    func startCapture() throws {
        bufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        _bufferLimitReached = false
        bufferLock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16 kHz, mono, 32-bit float (for AVAudioConverter)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.converterSetupFailed
        }

        // Create the resampling converter (hardware rate → 16kHz mono)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterSetupFailed
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate output frame count based on sample rate ratio
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0 else { return }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
                return
            }

            // Convert (resample) the input buffer to 16kHz mono float
            var error: NSError?
            var inputConsumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error != nil || outputBuffer.frameLength == 0 { return }

            // Convert float32 samples to Int16 PCM
            guard let floatData = outputBuffer.floatChannelData else { return }
            let frameLength = Int(outputBuffer.frameLength)
            var int16Samples = [Int16]()
            int16Samples.reserveCapacity(frameLength)

            for i in 0..<frameLength {
                let clamped = max(-1.0, min(1.0, floatData[0][i]))
                int16Samples.append(Int16(clamped * Float(Int16.max)))
            }

            let chunk = Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)

            self.bufferLock.lock()
            guard self.pcmBuffer.count < AudioCaptureService.maxBufferBytes else {
                self._bufferLimitReached = true
                self.bufferLock.unlock()
                return
            }
            self.pcmBuffer.append(chunk)
            self.bufferLock.unlock()
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stopCapture() throws -> CapturedAudio {
        guard isCapturing else { throw AudioCaptureError.captureNotRunning }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        bufferLock.lock()
        let captured = pcmBuffer
        bufferLock.unlock()

        return CapturedAudio(pcm: captured, sampleRate: Self.targetSampleRate)
    }
}
```

Key changes:
- `AVAudioConverter` resamples from hardware rate (48kHz) to 16kHz mono in real-time
- `sampleRate` is always `16_000` — backend never needs to resample
- Buffer size increased to 4096 for smoother converter throughput
- Payload is 3x smaller (16kHz vs 48kHz), cutting network latency

**Step 2: Build to verify no compile errors**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Services/AudioCaptureService.swift
git commit -m "fix: resample audio to 16kHz client-side via AVAudioConverter

Whisper expects 16kHz input. Previously captured at hardware rate (48kHz)
and relied on backend torchaudio resampling. Now resampled at capture time
using Apple's AVAudioConverter (vDSP/Accelerate-backed), producing higher
quality input and 3x smaller payloads."
```

---

### Task 4: Default Insert Behavior to Raw (Skip FLAN-T5)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/SettingsCoordinator.swift:130-133`

**Step 1: Change the default fallback**

In `SettingsCoordinator.swift`, replace lines 130-133:

```swift
        } else {
            state.insertBehavior = .autoInsertRaw
            defaults.set(state.insertBehavior.rawValue, forKey: insertBehaviorKey)
        }
```

This only affects NEW users (no saved preference). Existing users keep their chosen setting.

**Step 2: Build to verify**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: `Build complete!`

**Step 3: Reset the local UserDefaults key to test the new default**

To test this on YOUR machine (since you already have a saved preference), you need to delete the existing key:

```bash
defaults delete local.voxflow.app voxflow.dictation.insertBehavior 2>/dev/null || true
```

**Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/SettingsCoordinator.swift
git commit -m "fix: default insert behavior to raw (skip FLAN-T5 cleanup)

FLAN-T5-Small cleanup often degrades marginal Whisper transcriptions.
Default to inserting raw Whisper output for accuracy. Users can re-enable
cleanup via Settings > Insert Behavior > Auto-Insert Light/Polish."
```

---

### Task 5: Build App Bundle and Verify

**Files:** None (build + test only)

**Step 1: Kill any running VoxFlow instances**

```bash
pkill -f VoxFlowLocal 2>/dev/null; pkill -f "server.py" 2>/dev/null; sleep 1
```

**Step 2: Build the app bundle**

```bash
cd /Users/zola/Documents/CODING/voxflow-local && ./scripts/build_app_bundle.sh --menu-bar-only
```

Expected: `[bundle] done`

**Step 3: Install and launch**

```bash
./scripts/install_app_bundle.sh
open ~/Applications/VoxFlow.app
```

**Step 4: Wait for backend readiness**

```bash
for i in $(seq 1 12); do
  resp=$(curl -s http://127.0.0.1:8765/v1/health 2>/dev/null || echo "unreachable")
  if echo "$resp" | grep -q '"model_loaded":"true"'; then echo "Backend ready!"; break; fi
  sleep 5
done
```

**Step 5: API smoke test with golden clip at 16kHz**

```bash
CLIP="/Users/zola/Documents/CODING/voxflow-local/backend/tests/fixtures/golden_clips/dashboard_phrase.wav"
PCM_B64=$(python3 -c "
import base64
with open('$CLIP', 'rb') as f:
    pcm = f.read()[44:]
    print(base64.b64encode(pcm).decode())
")
curl -s -X POST http://127.0.0.1:8765/v1/transcribe \
  -H "Content-Type: application/json" \
  -d "{\"session_id\": \"test-1\", \"audio_pcm16le\": \"$PCM_B64\", \"sample_rate\": 16000}" | python3 -m json.tool
```

Expected: Non-empty `text` field with `confidence_estimate > 0`

**Step 6: Check Console.app for diagnostic logs**

Open Console.app, filter by `local.voxflow.app`. Attempt a dictation in TextEdit. You should see log lines like:
- `startCapture blocked: ...` (if any guard fails)
- `Transcription: '...' (confidence=..., latency=...ms)`
- `Insert attempt: method=..., success=..., fallback=..., app=...`

**Step 7: Reset insertBehavior preference to test new default**

```bash
defaults delete local.voxflow.app voxflow.dictation.insertBehavior 2>/dev/null || true
```

Then restart VoxFlow and verify it uses raw insertion (no cleanup delay).
