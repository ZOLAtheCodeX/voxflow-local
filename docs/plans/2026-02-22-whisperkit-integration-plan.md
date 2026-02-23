# WhisperKit Native STT Integration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add WhisperKit as a native Swift STT backend, bypassing the Python HTTP roundtrip for ~3-5x latency improvement on dictation.

**Architecture:** New `STTBackend.whisperKit` enum case. `WhisperKitSTTService` wraps WhisperKit library, loads CoreML model from `models/` at startup, exposes `transcribe(CapturedAudio) -> TranscribeResponse`. `AppCoordinator.finishCaptureAndTranscribe()` branches on backend selection. Hallucination filter ported from Python to Swift. Backend still used for cleanup/translation/privacy.

**Tech Stack:** Swift 6.2, WhisperKit (SPM), CoreML, Apple Neural Engine, macOS 14+

**Design doc:** `docs/plans/2026-02-22-whisperkit-integration-design.md`

---

### Task 1: Add WhisperKit SPM dependency

**Files:**
- Modify: `Package.swift:1-24`

**Step 1: Add dependency and target linkage**

In `Package.swift`, add the `dependencies` array and link `WhisperKit` to the `VoxFlowApp` target. Replace the entire file with:

```swift
// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "voxflow-local",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoxFlowLocal", targets: ["VoxFlowApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoxFlowApp",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/VoxFlowApp"
        ),
        .testTarget(
            name: "VoxFlowAppTests",
            dependencies: ["VoxFlowApp"],
            path: "Tests/VoxFlowAppTests"
        )
    ]
)
```

**Step 2: Resolve dependencies**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift package resolve`
Expected: Dependencies resolve successfully. `Package.resolved` updated.

**Step 3: Build to verify compilation**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: Build succeeds. WhisperKit and swift-transformers compile.

**Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add WhisperKit SPM dependency

WhisperKit 0.9.0+ for native CoreML/ANE speech-to-text.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 2: Add HallucinationFilter (port from Python)

**Files:**
- Create: `Sources/VoxFlowApp/Services/HallucinationFilter.swift`
- Create: `Tests/VoxFlowAppTests/HallucinationFilterTests.swift`

**Step 1: Write the failing tests**

Create `Tests/VoxFlowAppTests/HallucinationFilterTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

final class HallucinationFilterTests: XCTestCase {

    // MARK: - Always-filtered phrases

    func testAlwaysFilteredThankYouForWatching() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you for watching.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you for watching!", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("thanks for watching.", shortAudio: false))
    }

    func testAlwaysFilteredSubscribe() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Subscribe to my channel.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Like and subscribe.", shortAudio: false))
    }

    func testAlwaysFilteredMusicNotes() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("♪", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("♪♪♪", shortAudio: false))
    }

    func testAlwaysFilteredEllipsis() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("...", shortAudio: false))
    }

    func testAlwaysFilteredEmpty() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("   ", shortAudio: false))
    }

    // MARK: - Short-audio-only phrases

    func testShortOnlyFilteredOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you", shortAudio: true))
    }

    func testShortOnlyPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Thank you.", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Bye.", shortAudio: false))
    }

    // MARK: - Repeated word detection

    func testRepeatedWordFilteredOnShortAudio() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: true))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("the the the the", shortAudio: true))
    }

    func testRepeatedWordPassedOnLongAudio() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("you you you", shortAudio: false))
    }

    func testTwoRepeatedWordsNotFiltered() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("yes yes", shortAudio: true))
    }

    // MARK: - Valid text passes

    func testValidDictationPasses() {
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Send the report to the team by Friday", shortAudio: false))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("Hello world", shortAudio: true))
        XCTAssertFalse(HallucinationFilter.isLikelyHallucination("I need to update the project plan", shortAudio: false))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("THANK YOU FOR WATCHING.", shortAudio: false))
        XCTAssertTrue(HallucinationFilter.isLikelyHallucination("subscribe to my channel.", shortAudio: false))
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter HallucinationFilterTests 2>&1 | tail -5`
Expected: FAIL — `HallucinationFilter` type not found.

**Step 3: Implement HallucinationFilter**

Create `Sources/VoxFlowApp/Services/HallucinationFilter.swift`:

```swift
import Foundation

enum HallucinationFilter {
    private static let alwaysFiltered: Set<String> = Set([
        "thank you for watching.",
        "thank you for watching!",
        "thanks for watching.",
        "thanks for watching!",
        "thank you so much for watching.",
        "thank you so much for watching!",
        "subscribe to my channel.",
        "subscribe to the channel.",
        "subscribe for more.",
        "subscribe for more!",
        "please subscribe.",
        "like and subscribe.",
        "please like and subscribe.",
        "♪",
        "♪♪",
        "♪♪♪",
        "...",
    ])

    private static let shortOnlyFiltered: Set<String> = Set([
        "thank you.",
        "thanks.",
        "bye.",
        "goodbye.",
        "you",
    ])

    static func isLikelyHallucination(_ text: String, shortAudio: Bool) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return true }
        let lowered = stripped.lowercased()

        if alwaysFiltered.contains(lowered) {
            return true
        }

        if shortAudio {
            if shortOnlyFiltered.contains(lowered) {
                return true
            }
            let words = lowered.split(separator: " ")
            if words.count >= 3, Set(words).count == 1 {
                return true
            }
        }

        return false
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter HallucinationFilterTests 2>&1 | tail -5`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/HallucinationFilter.swift Tests/VoxFlowAppTests/HallucinationFilterTests.swift
git commit -m "feat: port Whisper hallucination filter to Swift

Two-tier filter: always-filtered phrases (YouTube/podcast artifacts)
and short-audio-only phrases (single words, repeated words).
Matches backend/app/server.py lines 707-768.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Add STTBackend.whisperKit enum case

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift:90-107`
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift:429-437`
- Modify: `Sources/VoxFlowApp/State/AppState.swift:53` (add whisperKitReady)
- Test: `Tests/VoxFlowAppTests/AppModelTests.swift`

**Step 1: Write the failing test**

Add to `Tests/VoxFlowAppTests/AppModelTests.swift` after `testSTTBackendDisplayNamesUnique` (line 45):

```swift
    func testSTTBackendWhisperKitCodableRoundTrip() throws {
        let backend = STTBackend.whisperKit
        let data = try JSONEncoder().encode(backend)
        let decoded = try JSONDecoder().decode(STTBackend.self, from: data)
        XCTAssertEqual(decoded, .whisperKit)
    }

    func testSTTBackendWhisperKitDisplayName() {
        XCTAssertEqual(STTBackend.whisperKit.displayName, "WhisperKit (Local, Neural Engine)")
    }
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter AppModelTests/testSTTBackendWhisperKitCodableRoundTrip 2>&1 | tail -5`
Expected: FAIL — `whisperKit` case not found.

**Step 3: Add the enum case and update views**

In `Sources/VoxFlowApp/Models/AppModels.swift`, replace lines 90-107:

```swift
enum STTBackend: String, CaseIterable, Identifiable, Codable {
    case voxtral
    case whisper
    case whisperKit
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voxtral:
            return "Voxtral (Local)"
        case .whisper:
            return "Whisper (Local)"
        case .whisperKit:
            return "WhisperKit (Local, Neural Engine)"
        case .openAI:
            return "OpenAI STT"
        }
    }
}
```

In `Sources/VoxFlowApp/Views/SettingsView.swift`, replace lines 429-437 (the `sttBackendNote` computed property):

```swift
    private var sttBackendNote: String {
        switch state.sttBackend {
        case .voxtral:
            return "Voxtral local STT is optimized for your default offline workflow."
        case .whisper:
            return "Whisper local STT uses an open-source OpenAI Whisper model on-device."
        case .whisperKit:
            return "WhisperKit runs Whisper on Apple Neural Engine. Fastest local option. No network access."
        case .openAI:
            return "OpenAI STT sends microphone audio to your configured OpenAI endpoint."
        }
    }
```

In `Sources/VoxFlowApp/State/AppState.swift`, after line 53 (`@Published var backendReadyForDictation = false`), add:

```swift
    @Published var whisperKitReady = false
```

**Step 4: Build and run tests**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: Build succeeds.

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter AppModelTests 2>&1 | tail -10`
Expected: All tests PASS (existing `testSTTBackendDisplayNamesUnique` now checks 4 cases).

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift Sources/VoxFlowApp/Views/SettingsView.swift Sources/VoxFlowApp/State/AppState.swift Tests/VoxFlowAppTests/AppModelTests.swift
git commit -m "feat: add STTBackend.whisperKit enum case

New option in Settings picker: 'WhisperKit (Local, Neural Engine)'.
Adds whisperKitReady state property.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Create WhisperKitSTTService

**Files:**
- Create: `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift`
- Create: `Tests/VoxFlowAppTests/WhisperKitSTTServiceTests.swift`

**Step 1: Write the failing tests**

Create `Tests/VoxFlowAppTests/WhisperKitSTTServiceTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

final class WhisperKitSTTServiceTests: XCTestCase {

    // MARK: - PCM conversion

    func testConvertPCMInt16ToFloat() {
        // Silence: all zeros
        let silence = Data(repeating: 0, count: 4) // 2 samples of Int16(0)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(silence)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001)
    }

    func testConvertPCMMaxPositive() {
        // Int16.max = 32767
        var sample = Int16.max
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
    }

    func testConvertPCMMaxNegative() {
        // Int16.min = -32768
        var sample = Int16.min
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], -1.0, accuracy: 0.001)
    }

    func testConvertPCMOddByteCountTruncates() {
        // 3 bytes → only 1 complete Int16 sample (2 bytes), last byte dropped
        let data = Data([0x00, 0x00, 0xFF])
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - Model path resolution

    func testResolveModelFolder() {
        let modelsDir = "/tmp/test-models"
        let folder = WhisperKitSTTService.resolveModelFolder(
            modelsDir: modelsDir,
            modelName: "openai_whisper-small.en"
        )
        XCTAssertEqual(folder, "/tmp/test-models/whisperkit-coreml__openai_whisper-small.en")
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter WhisperKitSTTServiceTests 2>&1 | tail -5`
Expected: FAIL — `WhisperKitSTTService` type not found.

**Step 3: Implement WhisperKitSTTService**

Create `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift`:

```swift
@preconcurrency import WhisperKit
import Foundation
import os.log

@MainActor
final class WhisperKitSTTService {
    private let log = Logger(subsystem: "local.voxflow.app", category: "WhisperKitSTT")
    private var pipe: WhisperKit?
    private(set) var isLoaded = false

    static func resolveModelFolder(modelsDir: String, modelName: String) -> String {
        (modelsDir as NSString).appendingPathComponent("whisperkit-coreml__\(modelName)")
    }

    func load(modelFolder: String) async throws {
        log.info("Loading WhisperKit model from \(modelFolder)")
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            ),
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        isLoaded = true
        log.info("WhisperKit model loaded successfully")
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        guard let pipe else {
            throw WhisperKitSTTError.modelNotLoaded
        }

        let started = ContinuousClock.now
        let floatSamples = Self.convertPCMInt16ToFloat(audio.pcm)

        let results = try await pipe.transcribe(
            audioArray: floatSamples,
            decodeOptions: DecodingOptions(
                language: "en",
                wordTimestamps: true
            )
        )

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = started.duration(to: .now)
        let latencyMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)

        let confidence: Double = {
            guard let first = results.first, let seg = first.segments.first else { return 0.0 }
            // avgLogprob is negative; convert to 0-1 range using sigmoid-like mapping
            let prob = exp(seg.avgLogprob)
            return min(1.0, max(0.0, prob))
        }()

        // Apply hallucination filter
        let audioDurationS = Double(audio.pcm.count) / (audio.sampleRate * 2.0) // 2 bytes per Int16 sample
        let isShort = audioDurationS < 3.0
        if HallucinationFilter.isLikelyHallucination(text, shortAudio: isShort) {
            log.info("Filtered hallucination (%.1fs, short=\(isShort)): '\(text.prefix(60))'")
            return TranscribeResponse(
                text: "",
                isFinal: true,
                latencyMs: latencyMs,
                confidenceEstimate: 0.0,
                processingTimeMs: latencyMs
            )
        }

        log.info("Transcribed in \(latencyMs)ms: '\(text.prefix(80))' (confidence=\(String(format: "%.2f", confidence)))")

        return TranscribeResponse(
            text: text,
            isFinal: true,
            latencyMs: latencyMs,
            confidenceEstimate: confidence,
            processingTimeMs: latencyMs
        )
    }

    func unload() {
        pipe = nil
        isLoaded = false
        log.info("WhisperKit model unloaded")
    }

    // MARK: - Audio Conversion

    static func convertPCMInt16ToFloat(_ pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        return pcmData.withUnsafeBytes { raw in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            return (0..<sampleCount).map { i in
                Float(int16Buffer[i]) / Float(Int16.max)
            }
        }
    }
}

enum WhisperKitSTTError: LocalizedError {
    case modelNotLoaded
    case modelNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "WhisperKit model not loaded"
        case .modelNotFound(let path):
            return "WhisperKit model not found at: \(path)"
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test --filter WhisperKitSTTServiceTests 2>&1 | tail -10`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/WhisperKitSTTService.swift Tests/VoxFlowAppTests/WhisperKitSTTServiceTests.swift
git commit -m "feat: add WhisperKitSTTService with CoreML/ANE inference

Loads pre-downloaded model from models/ dir with download: false.
Converts PCM Int16 → Float for WhisperKit API. Applies hallucination
filter in-process. Returns TranscribeResponse matching backend format.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 5: Wire WhisperKit into AppCoordinator

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:19-44` (add service property)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:75-128` (warmup + readiness)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:184-208` (startCapture guard)
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift:254-335` (finishCaptureAndTranscribe)
- Modify: `Sources/VoxFlowApp/Services/SettingsCoordinator.swift:174-179` (selectSTTBackend)

**Step 1: Add WhisperKitSTTService property to AppCoordinator**

In `Sources/VoxFlowApp/AppCoordinator.swift`, after line 27 (`private let sessionMemory = SessionMemoryStore(capacity: 20)`), add:

```swift
    private let whisperKitService = WhisperKitSTTService()
```

**Step 2: Update warmup() to load WhisperKit model**

In `Sources/VoxFlowApp/AppCoordinator.swift`, replace the `warmup()` method (lines 75-85) with:

```swift
    func warmup() async {
        // Load WhisperKit model if selected
        if state.sttBackend == .whisperKit {
            await loadWhisperKitModel()
        }

        // Always poll backend readiness (still needed for cleanup/translation)
        for attempt in 0..<24 {
            guard !Task.isCancelled else { return }
            await refreshBackendReadiness()
            if state.backendReadyForDictation {
                return
            }
            // If WhisperKit is ready, we can dictate even without backend
            if state.sttBackend == .whisperKit && state.whisperKitReady {
                return
            }
            let delay: UInt64 = attempt < 4 ? 2_000_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func loadWhisperKitModel() async {
        let modelsDir = ProcessInfo.processInfo.environment["VOXFLOW_MODELS_DIR"]
            ?? (ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"].map { $0 + "/models" })
            ?? "./models"
        let modelName = "openai_whisper-small.en"
        let modelFolder = WhisperKitSTTService.resolveModelFolder(modelsDir: modelsDir, modelName: modelName)

        state.statusLine = "Loading WhisperKit model..."
        do {
            try await whisperKitService.load(modelFolder: modelFolder)
            state.whisperKitReady = true
            state.statusLine = "WhisperKit ready"
        } catch {
            state.whisperKitReady = false
            state.statusLine = "WhisperKit failed: \(error.localizedDescription)"
            log.error("WhisperKit load failed: \(error.localizedDescription)")
        }
    }
```

**Step 3: Update startCapture() readiness guard**

In `Sources/VoxFlowApp/AppCoordinator.swift`, replace lines 204-208 (the `backendReadyForDictation` guard):

```swift
        if !state.backendReadyForDictation {
            log.warning("startCapture blocked: backend not ready for dictation")
            state.statusLine = "Backend not ready — wait for model warmup"
            return
        }
```

with:

```swift
        let canTranscribe = state.backendReadyForDictation
            || (state.sttBackend == .whisperKit && state.whisperKitReady)
        if !canTranscribe {
            log.warning("startCapture blocked: no STT backend ready (backend=\(state.backendReadyForDictation), whisperKit=\(state.whisperKitReady))")
            state.statusLine = state.sttBackend == .whisperKit
                ? "WhisperKit not ready — wait for model load"
                : "Backend not ready — wait for model warmup"
            return
        }
```

**Step 4: Branch finishCaptureAndTranscribe() on STT backend**

In `Sources/VoxFlowApp/AppCoordinator.swift`, replace lines 285-292 (the transcription call):

```swift
            let sessionID = "session-\(sessionCounter)"
            let transcription = try await BackendAPIClient.transcribe(
                sessionID: sessionID,
                audioPCM: capturedAudio.pcm,
                sampleRate: Int(capturedAudio.sampleRate),
                chunkIndex: 0,
                languageHint: "en"
            )
```

with:

```swift
            let sessionID = "session-\(sessionCounter)"
            let transcription: TranscribeResponse
            if state.sttBackend == .whisperKit {
                transcription = try await whisperKitService.transcribe(capturedAudio)
            } else {
                transcription = try await BackendAPIClient.transcribe(
                    sessionID: sessionID,
                    audioPCM: capturedAudio.pcm,
                    sampleRate: Int(capturedAudio.sampleRate),
                    chunkIndex: 0,
                    languageHint: "en"
                )
            }
```

**Step 5: Update SettingsCoordinator.selectSTTBackend to handle WhisperKit**

In `Sources/VoxFlowApp/Services/SettingsCoordinator.swift`, replace `selectSTTBackend` method (lines 174-179):

```swift
    func selectSTTBackend(_ backend: STTBackend) {
        guard state.sttBackend != backend else { return }
        state.sttBackend = backend
        UserDefaults.standard.set(backend.rawValue, forKey: sttBackendKey)

        if backend == .whisperKit {
            // WhisperKit is in-process — no backend restart needed
            state.statusLine = "STT backend: \(backend.displayName)"
        } else {
            restartBackendWithCurrentConfiguration(status: "STT backend: \(backend.displayName)")
        }
    }
```

**Step 6: Build and run tests**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build 2>&1 | tail -5`
Expected: Build succeeds.

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test 2>&1 | tail -10`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Services/SettingsCoordinator.swift
git commit -m "feat: wire WhisperKit into AppCoordinator transcription pipeline

Branch in finishCaptureAndTranscribe(): WhisperKit bypasses HTTP,
Python backends use existing BackendAPIClient path. Warmup loads
WhisperKit model when selected. Readiness accepts WhisperKit OR
backend. Settings switch doesn't restart Python backend.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Create model download script

**Files:**
- Create: `scripts/download_whisperkit_model.sh`

**Step 1: Create the download script**

Create `scripts/download_whisperkit_model.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_DIR="${VOXFLOW_MODELS_DIR:-$PROJECT_ROOT/models}"

MODEL_REPO="argmaxinc/whisperkit-coreml"
MODEL_NAME="${1:-openai_whisper-small.en}"
TARGET_DIR="$MODELS_DIR/whisperkit-coreml__${MODEL_NAME}"

echo "=== WhisperKit Model Download ==="
echo "Model:  $MODEL_NAME"
echo "Repo:   $MODEL_REPO"
echo "Target: $TARGET_DIR"
echo ""

if [[ -d "$TARGET_DIR" ]] && [[ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]]; then
    echo "Model already exists at $TARGET_DIR"
    echo "To re-download, remove the directory first:"
    echo "  rm -rf \"$TARGET_DIR\""
    exit 0
fi

mkdir -p "$TARGET_DIR"

# Try huggingface-cli first (fastest, handles LFS correctly)
if command -v huggingface-cli &>/dev/null; then
    echo "Using huggingface-cli..."
    huggingface-cli download "$MODEL_REPO" \
        --include "${MODEL_NAME}/*" \
        --local-dir "$MODELS_DIR/whisperkit-coreml-download" \
        --local-dir-use-symlinks false

    # Move the model subfolder to target
    if [[ -d "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}" ]]; then
        mv "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}"/* "$TARGET_DIR/"
        rm -rf "$MODELS_DIR/whisperkit-coreml-download"
        echo ""
        echo "Download complete: $TARGET_DIR"
        echo "Contents:"
        ls -lh "$TARGET_DIR"
    else
        echo "ERROR: Expected model directory not found after download"
        rm -rf "$MODELS_DIR/whisperkit-coreml-download"
        exit 1
    fi

# Fallback: try venv's huggingface-cli
elif [[ -x "$PROJECT_ROOT/.venv/bin/huggingface-cli" ]]; then
    echo "Using venv huggingface-cli..."
    "$PROJECT_ROOT/.venv/bin/huggingface-cli" download "$MODEL_REPO" \
        --include "${MODEL_NAME}/*" \
        --local-dir "$MODELS_DIR/whisperkit-coreml-download" \
        --local-dir-use-symlinks false

    if [[ -d "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}" ]]; then
        mv "$MODELS_DIR/whisperkit-coreml-download/${MODEL_NAME}"/* "$TARGET_DIR/"
        rm -rf "$MODELS_DIR/whisperkit-coreml-download"
        echo ""
        echo "Download complete: $TARGET_DIR"
        echo "Contents:"
        ls -lh "$TARGET_DIR"
    else
        echo "ERROR: Expected model directory not found after download"
        rm -rf "$MODELS_DIR/whisperkit-coreml-download"
        exit 1
    fi

else
    echo "ERROR: huggingface-cli not found."
    echo "Install it: pip install huggingface-hub"
    echo "Or bootstrap the backend: ./scripts/bootstrap_backend.sh"
    exit 1
fi

echo ""
echo "Done. Set VOXFLOW_STT_BACKEND=whisperKit and restart VoxFlow."
```

**Step 2: Make executable and test**

Run: `chmod +x /Users/zola/Documents/CODING/voxflow-local/scripts/download_whisperkit_model.sh`

Run: `cd /Users/zola/Documents/CODING/voxflow-local && bash scripts/download_whisperkit_model.sh --help 2>&1 || true`
Expected: Shows usage or attempts download (won't fail fatally — the script guards for existing models).

**Step 3: Commit**

```bash
git add scripts/download_whisperkit_model.sh
git commit -m "feat: add WhisperKit CoreML model download script

Downloads openai_whisper-small.en from argmaxinc/whisperkit-coreml
to models/whisperkit-coreml__openai_whisper-small.en/.
Uses huggingface-cli with fallback to venv path.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Update CLAUDE.md and README.md

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

**Step 1: Run full test suite**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift test 2>&1 | tail -10`
Expected: All tests pass.

**Step 2: Update CLAUDE.md**

In `CLAUDE.md`, in the Architecture section after `models/` line, add:

```
  whisperkit-coreml__openai_whisper-small.en/  Pre-downloaded WhisperKit CoreML model
```

In the "Key Patterns > Swift" section, add bullet:

```
- **WhisperKit native STT**: `WhisperKitSTTService` wraps WhisperKit library for in-process CoreML/ANE transcription. Loaded from `models/whisperkit-coreml__openai_whisper-small.en/` with `download: false` (zero network). Selected via `STTBackend.whisperKit` in Settings. Falls through to same `TranscribeResponse` type as backend STT path.
```

In the "Environment Variables" table, add row:

```
| `VOXFLOW_STT_BACKEND` | STT engine: `voxtral`, `whisper`, `whisperKit`, `openai` | `voxtral` |
```

(Replace the existing row that lists only three options.)

In the "Do Not" section, add:

```
- Use `WhisperKit()` default init (it phones home to HuggingFace) — always use `WhisperKitConfig(modelFolder:, download: false)`
```

Update the test count to reflect new tests.

**Step 3: Update README.md**

In the README under "Implemented" features, add:

```
- WhisperKit native STT — CoreML/Apple Neural Engine, in-process inference, zero network
```

**Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: update conventions for WhisperKit native STT integration

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 8: Download model and manual smoke test

**No code changes — verification only.**

**Step 1: Download the WhisperKit CoreML model**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && ./scripts/download_whisperkit_model.sh`
Expected: Model downloaded to `models/whisperkit-coreml__openai_whisper-small.en/`.

**Step 2: Build app bundle**

Run: `cd /Users/zola/Documents/CODING/voxflow-local && swift build`
Expected: Build succeeds.

**Step 3: Launch and test**

1. Start backend: `./scripts/run_backend.sh`
2. Run app: `swift run VoxFlowLocal`
3. Open Settings → change STT Backend to "WhisperKit (Local, Neural Engine)"
4. Wait for "WhisperKit ready" in status line (first load may take 10-30s for ANE compilation)
5. Open TextEdit, place cursor
6. Hold Fn → speak → release Fn
7. Verify text appears in TextEdit

**Step 4: Test checklist**

| # | Test | Expected |
|---|------|----------|
| 1 | Short dictation (~3s) | Text inserted, fast (<1s) |
| 2 | Medium dictation (~15s) | Full text, no truncation |
| 3 | Long dictation (~30s) | Full text, under 2s processing |
| 4 | Switch back to Voxtral in Settings | Backend restarts, dictation works via HTTP |
| 5 | Switch to WhisperKit while backend is stopped | Dictation still works (in-process) |
| 6 | Hallucination test: very short tap (<0.3s) | "Too short" message (existing guard) |

---

## Task Dependency Graph

```
Task 1 (SPM dependency)
  └→ Task 2 (HallucinationFilter)
  └→ Task 3 (STTBackend enum + AppState)
  └→ Task 4 (WhisperKitSTTService)
      └→ Task 5 (Wire into AppCoordinator)
          └→ Task 6 (Download script)
          └→ Task 7 (Docs)
          └→ Task 8 (Manual test)
```

Tasks 2, 3 depend only on Task 1.
Task 4 depends on Tasks 2 + 3.
Tasks 5-8 are sequential.
