# VoxFlow Cockpit Layer 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the Cockpit's live long-form capture loop (the missing keystone of Layer 0), then build Layer 1 power features — personal dictionary, Notion integration, voice snippets, workflow chains — each independently shippable.

**Architecture:** A new `@MainActor CockpitCaptureCoordinator` owns a dedicated `AudioCaptureService` and a serial flush loop that segments continuous audio into transcribed chunks fed to `LongFormSessionService.appendChunk`. The transcript becomes editable in the review state, which also provides the substrate for dictionary learning. Layer 1 features are local-first JSON-backed stores (`DictionaryStore`, `SnippetStore`, `ChainStore`) mirroring the existing `LongFormSessionService` persistence pattern, plus Notion routed through an MCP-client subprocess managed by the backend.

**Tech Stack:** Swift 6.2 (strict concurrency, `@MainActor` coordinators, `os.Logger`), SwiftUI (`VFDesignTokens`), `AVAudioEngine` capture, WhisperKit STT, Python FastAPI backend, Ollama/Gemma 4 for smart actions, XCTest + pytest.

---

## Decisions locked (this session)

- **Notion mechanism:** reuse the existing **Notion MCP** server — VoxFlow's *backend* acts as an MCP client spawning the Notion MCP server as a managed subprocess with headless credentials (Phase C). ⚠️ Highest-risk item — headless MCP auth without Claude running is unproven; Phase C carries a spike + fallback.
- **Sequencing:** **Dictionary first** (Phase B), after the L0 capture keystone (Phase A).
- **Plan shape:** one umbrella plan; Phase 0/A/B fully detailed (TDD), Phases C/D/E outlined and each becomes its own detailed plan when reached (per writing-plans scope-check — they are independent shippable subsystems).

## Why Phase A exists (review finding, 2026-05-27)

`LongFormSessionService.appendChunk(_:)` — the only way transcribed text enters a long-form session — has **zero production callers** (tests only). `⌘R` (`CockpitWindowView.swift:102`) calls `sessionService.start(...)`; `⌘.` calls `sessionService.stop()`; nothing routes mic audio → Whisper → `appendChunk` between them. `CockpitTranscriptView` is read-only by its own comment. So Layer 0's window/state-machine/persistence/smart-actions/MRU/undo are built and tested, but **you cannot actually dictate into the cockpit, nor edit the transcript** — both are prerequisites for the dictionary's apply pass (chunk-ingestion hook) and learning loop (review-edit hook). Phase A closes that gap before Layer 1 builds on it.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift` | **create** | `@MainActor` — owns a dedicated `AudioCaptureService` + serial flush loop; segments audio → chunks → `appendChunk` |
| `Sources/VoxFlowApp/Services/AudioCaptureService.swift` | modify | Conform to new `AudioCapturing` protocol (no behavior change) |
| `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift` | modify | Conform to new `ChunkTranscribing` protocol (no behavior change) |
| `Sources/VoxFlowApp/AppCoordinator.swift` | modify | Add `cockpitCapture` lazy property; construct it after `cockpitSessionService` + `whisperKitService` |
| `Sources/VoxFlowApp/Views/CockpitWindowView.swift` | modify | Route `⌘R`/`⌘.` to `cockpitCapture.startRecording/stopRecording` |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitTranscriptView.swift` | modify | Editable `TextEditor` in review state; focus-loss edit-commit hook |
| `Sources/VoxFlowApp/Services/DictionaryStore.swift` | **create** | `@MainActor ObservableObject` — JSON-backed dictionary; seed; apply + learn algorithms |
| `Sources/VoxFlowApp/Models/AppModels.swift` | modify | Add `DictionaryEntry` (and later `VoiceSnippet`, `WorkflowChain`, `ChainStep`) |
| `Sources/VoxFlowApp/Views/SettingsView.swift` | modify | `Section("Dictionary")` — list/add/delete |
| `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift` | modify | `dictionarySection` card (recent learned corrections) |
| `Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift` | **create** | Flush-loop unit tests with fakes |
| `Tests/VoxFlowAppTests/DictionaryStoreTests.swift` | **create** | apply + learn + persistence tests |

**Test conventions (from existing suite):** `XCTestCase`; `@MainActor func test_name()`; construct services with injected temp-dir URLs and the existing `SessionClock`/`SystemClock` (see `LongFormSessionServiceTests.swift`); synchronous calls where possible, `async` where the API is.

---

# Phase 0 — Close-out (operational, ~30 min)

Not TDD — operational housekeeping you said to keep. Do first; it de-risks everything downstream.

### Task 0.1: Run owed Ollama validations

- [ ] **Step 1: Ensure Ollama is up with the model pinned**

```bash
export OLLAMA_KEEP_ALIVE=24h
ollama serve >/tmp/ollama.log 2>&1 &
ollama pull gemma4:e4b-mlx
curl -s localhost:11434/api/ps   # confirm size_vram > 0 after a warm call
```

- [ ] **Step 2: Measure polish latency on this hardware**

```bash
./.venv/bin/python scripts/measure_polish_latency.py
```
Expected: prints cold + warm latency for the configured model. Record the numbers.

- [ ] **Step 3: Confirm guardrail trigger rate <15% on the golden set**

```bash
VOXFLOW_OLLAMA_GOLDEN=1 ./.venv/bin/python -m pytest backend/tests/test_polish_golden.py -v
```
Expected: PASS (the 9 normally-skipped live-Ollama tests now run and pass; guardrail trip rate under the documented threshold).

- [ ] **Step 4: Record results in the roadmap doc**

Edit `docs/plans/2026-05-25-stabilization-modernization-roadmap.md` — replace the Phase 3 "Local-validation owed to user" note with the measured latency numbers + golden-set result + date.

- [ ] **Step 5: Commit**

```bash
git add docs/plans/2026-05-25-stabilization-modernization-roadmap.md
git commit -m "docs(roadmap): record measured Ollama polish latency + golden-set guardrail rate"
```

### Task 0.2: Reconcile stale planning docs with master

- [ ] **Step 1: Update the shipping-status table**

In `docs/plans/2026-05-25-stabilization-modernization-roadmap.md`, change Phase 2 from "⚠️ Partial" to "✅ Shipped" (api/ split `endpoints.py`+`context.py` merged; all privacy-token tests pass) and Phase 5 from "⏳ In-flight" to "✅ Shipped" (all 5.1–5.8 complete per `progress.md`). Add a row: `Cockpit Layer 0 | ⚠️ Shell shipped, live capture pending (Phase A) | master | Window/state-machine/persistence/smart-actions/MRU/undo tested; audio→appendChunk loop NOT wired — see L1 plan Phase A.`

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-05-25-stabilization-modernization-roadmap.md
git commit -m "docs(roadmap): reconcile shipping status with master; flag L0 capture gap"
```

### Task 0.3: Restart the backend onto the merged composition root

- [ ] **Step 1: Replace the running pre-refactor backend**

```bash
lsof -nP -iTCP:8765 -sTCP:LISTEN | awk 'NR>1{print $2}' | xargs -r kill
./scripts/run_backend.sh & sleep 5
curl -s http://127.0.0.1:8765/v1/ready
```
Expected: `ready: true` from the freshly-started (merged-code) backend.

---

# Phase A — Complete Layer 0 capture (the keystone)

Wire live long-form dictation and make the transcript editable. Ships as one PR; after this you can actually dictate into the cockpit.

## Task A1: Extract capture/STT protocols for testability

**Files:**
- Modify: `Sources/VoxFlowApp/Services/AudioCaptureService.swift`
- Modify: `Sources/VoxFlowApp/Services/WhisperKitSTTService.swift`
- Create: `Sources/VoxFlowApp/Services/CockpitCaptureProtocols.swift`

- [ ] **Step 1: Define the protocols**

Create `Sources/VoxFlowApp/Services/CockpitCaptureProtocols.swift`:

```swift
import Foundation

/// Start/stop whole-clip audio capture. `AudioCaptureService` conforms as-is.
protocol AudioCapturing: AnyObject {
    func startCapture() throws
    func stopCapture() throws -> CapturedAudio
}

/// One-shot transcription of a captured clip. `WhisperKitSTTService` conforms as-is.
protocol ChunkTranscribing: AnyObject {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse
}
```

- [ ] **Step 2: Conform the concrete services (no behavior change)**

In `AudioCaptureService.swift`, change the class declaration to `final class AudioCaptureService: AudioCapturing {`.
In `WhisperKitSTTService.swift`, change to `@MainActor final class WhisperKitSTTService: ChunkTranscribing {` (it already has the exact `transcribe(_:) async throws -> TranscribeResponse` signature).

- [ ] **Step 3: Build to verify conformance**

Run: `swift build`
Expected: builds clean (the methods already match the protocol requirements).

- [ ] **Step 4: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCaptureProtocols.swift Sources/VoxFlowApp/Services/AudioCaptureService.swift Sources/VoxFlowApp/Services/WhisperKitSTTService.swift
git commit -m "refactor(cockpit): extract AudioCapturing + ChunkTranscribing protocols for L0 capture wiring"
```

## Task A2: CockpitCaptureCoordinator — the segmented flush loop

**Files:**
- Create: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift`
- Test: `Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift`

Design: the testable unit is `flushNow()`. The timer loop just calls it on an interval (like `LongFormSessionService`'s auto-save Task). Tests call `flushNow()` directly with fakes — no real time, no real audio.

- [ ] **Step 1: Write the failing test (fake-driven flush appends transcribed chunk)**

Create `Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

private final class FakeCapture: AudioCapturing {
    var startCount = 0
    var nextAudio: CapturedAudio
    init(nextAudio: CapturedAudio) { self.nextAudio = nextAudio }
    func startCapture() throws { startCount += 1 }
    func stopCapture() throws -> CapturedAudio { nextAudio }
}

private final class FakeTranscriber: ChunkTranscribing {
    var nextText: String = ""
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        // TranscribeResponse has no defaults — all 9 fields required (see BackendAPIClient.swift:3).
        TranscribeResponse(
            text: nextText, isFinal: true, latencyMs: 1, confidenceEstimate: 0.9,
            processingTimeMs: 1, stageTimingsMs: nil,
            modelLoadedBeforeRequest: nil, modelLoadedAfterRequest: nil, coldStart: nil)
    }
}

@MainActor
final class CockpitCaptureCoordinatorTests: XCTestCase {
    private func makeAudio(silent: Bool) -> CapturedAudio {
        // 0.5s of 16kHz mono PCM16: non-silent uses a constant non-zero sample.
        let samples = 8000
        var data = Data(count: samples * 2)
        // rmsEnergy = |sample|/Int16.max; isSilent = rmsEnergy < 0.003 (AudioCaptureService.swift:28).
        // Set the HIGH byte of each little-endian Int16 → 0x4000 = 16384 → ~0.5 amplitude, robustly non-silent.
        if !silent { for i in stride(from: 1, to: data.count, by: 2) { data[i] = 0x40 } }
        return CapturedAudio(pcm: data, sampleRate: 16000)
    }

    func test_flushNow_appends_transcribed_text_and_restarts_capture() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "hello world"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)

        coord.startRecording(targetApp: nil)         // starts session + capture
        XCTAssertEqual(capture.startCount, 1)
        await coord.flushNow()                         // stop→transcribe→append→restart

        XCTAssertEqual(session.currentSession?.transcript, "hello world")
        XCTAssertEqual(capture.startCount, 2)          // capture restarted for next window
        await coord.stopRecording()
    }

    func test_flushNow_skips_silent_audio() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: true))
        let transcriber = FakeTranscriber(); transcriber.nextText = "should not appear"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }

    func test_flushNow_skips_empty_transcription() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "   "
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter CockpitCaptureCoordinatorTests`
Expected: FAIL — `CockpitCaptureCoordinator` not defined.

- [ ] **Step 3: Implement `CockpitCaptureCoordinator`**

Create `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift`:

```swift
import Foundation
import os

/// Cockpit Layer 0 — live long-form capture loop.
///
/// Owns a *dedicated* `AudioCapturing` instance (never shared with the palette
/// path, whose start/stop lifecycle is independent). Segments continuous audio
/// into chunks by periodically stop→transcribe→append→restart, feeding text to
/// `LongFormSessionService.appendChunk`. The paragraph-break-on-silence logic
/// already lives in `appendChunk`, so this coordinator only produces text.
@MainActor
final class CockpitCaptureCoordinator {
    private let capture: AudioCapturing
    private let transcriber: ChunkTranscribing
    private let session: LongFormSessionService
    private let flushIntervalNs: UInt64
    private let minChunkBytes: Int
    private let log = Logger(subsystem: "local.voxflow.app", category: "CockpitCaptureCoordinator")
    private var loopTask: Task<Void, Never>?
    private var isFlushing = false

    init(
        capture: AudioCapturing,
        transcriber: ChunkTranscribing,
        session: LongFormSessionService,
        flushIntervalNs: UInt64 = 5_000_000_000,
        minChunkBytes: Int = 8_000
    ) {
        self.capture = capture
        self.transcriber = transcriber
        self.session = session
        self.flushIntervalNs = flushIntervalNs
        self.minChunkBytes = minChunkBytes
    }

    func startRecording(targetApp: FocusTargetSnapshot?) {
        guard case .idle = session.state else { return }
        session.start(targetApp: targetApp)
        do { try capture.startCapture() } catch {
            log.error("startCapture failed: \(error.localizedDescription)")
            session.reset()
            return
        }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.flushIntervalNs ?? 5_000_000_000)
                guard let self else { return }
                await self.flushNow()
            }
        }
    }

    func stopRecording() async {
        loopTask?.cancel()
        loopTask = nil
        await flushNow()          // drain the final window
        try? _ = capture.stopCapture()
        session.stop()
    }

    /// Stop→validate→transcribe→append→restart. Serialized: a second call while
    /// one is in flight is dropped (the timer cadence gates normal flow).
    func flushNow() async {
        guard !isFlushing, case .recording = session.state else { return }
        isFlushing = true
        defer { isFlushing = false }

        let audio: CapturedAudio
        do { audio = try capture.stopCapture() } catch {
            log.error("stopCapture failed: \(error.localizedDescription)")
            return
        }
        // Restart immediately so the next window accumulates while we transcribe.
        try? capture.startCapture()

        guard !audio.isSilent, audio.pcm.count >= minChunkBytes else { return }
        do {
            let response = try await transcriber.transcribe(audio)
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            session.appendChunk(text)
        } catch {
            log.error("chunk transcription failed: \(error.localizedDescription)")
        }
    }
}
```

> Note: `CapturedAudio` (`AudioCaptureService.swift:6`) is `struct { let pcm: Data; let sampleRate: Double }` with computed `rmsEnergy`/`isSilent` and no custom init — so the memberwise `init(pcm:sampleRate:)` exists and is reachable from the test target via `@testable import`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter CockpitCaptureCoordinatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift
git commit -m "feat(cockpit): segmented long-form capture loop (CockpitCaptureCoordinator) + tests"
```

## Task A3: Construct + wire the coordinator into the cockpit

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (near the `cockpitSessionService` lazy property, ~`:106`)
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift` (`:102` and `:105`)

- [ ] **Step 1: Add the lazy property on AppCoordinator**

After the `cockpitSessionService` lazy property (~`:110`), add:

```swift
private(set) lazy var cockpitCapture: CockpitCaptureCoordinator = {
    CockpitCaptureCoordinator(
        capture: AudioCaptureService(),
        transcriber: whisperKitService,
        session: cockpitSessionService
    )
}()
```

> If `whisperKitService` is `private`, change it to `private(set)` so the lazy initializer can read it. Confirm `whisperKitService` is non-optional in the WhisperKit configuration; if it is optional, guard and fall back to leaving the cockpit capture unwired (log a warning) rather than force-unwrapping.

- [ ] **Step 2: Route the keyboard shortcuts**

In `CockpitWindowView.swift`, the `KeyEventBridge` handler currently calls `sessionService.start(targetApp: state.focusTarget)` (`:102`) and `sessionService.stop()` (`:105`). Replace with calls to the coordinator. The view needs access to `appCoordinator.cockpitCapture`; pass it in (the view already references `sessionService`). Change `⌘R` branch to:

```swift
coordinator.cockpitCapture.startRecording(targetApp: state.focusTarget)
```
and `⌘.`/`esc` branch to:
```swift
Task { await coordinator.cockpitCapture.stopRecording() }
```
where `coordinator` is the `AppCoordinator` already in scope (or inject `cockpitCapture` as a view property if the window builds without the full coordinator).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds clean.

- [ ] **Step 4: Manual smoke (REQUIRED — this is the whole point of Phase A)**

```bash
open ~/Applications/VoxFlow.app   # stable TCC identity; never raw Mach-O
```
Open cockpit (`⌥⌘V`), press `⌘R`, speak two sentences with a pause, press `⌘.`. Expected: transcript fills with your words; a `\n\n` paragraph break appears after the ≥4s pause; session JSON written under `~/Library/Application Support/VoxFlow/sessions/`. If nothing appears, check mic permission + that `whisperKitService` is non-nil.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Views/CockpitWindowView.swift
git commit -m "feat(cockpit): wire CockpitCaptureCoordinator to ⌘R/⌘. — live long-form capture works"
```

## Task A4: Make the review transcript editable + edit-commit hook

**Files:**
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitTranscriptView.swift`

Editable only in `.reviewing` state (recording appends chunks live). Capture a baseline on focus-gain and fire `onEditCommit(before, after)` on focus-loss — the learning hook Phase B consumes. Edits persist via the existing `LongFormSessionService.setTranscript(_:)`.

- [ ] **Step 1: Add editable state + commit hook to the view**

Replace the read-only `Text(session.transcript...)` with a state-gated editor:

```swift
struct CockpitTranscriptView: View {
    @ObservedObject var sessionService: LongFormSessionService
    var onEditCommit: ((_ before: String, _ after: String) -> Void)? = nil

    @State private var draft: String = ""
    @State private var baseline: String = ""
    @FocusState private var editing: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                if let session = sessionService.currentSession {
                    crumbs(session)
                    if sessionService.state == .reviewing {
                        TextEditor(text: $draft)
                            .font(VF.bodyFont)
                            .frame(minHeight: 200)
                            .focused($editing)
                            .onChange(of: editing) { _, isEditing in
                                if isEditing { baseline = draft }
                                else { commitEdit() }
                            }
                    } else {
                        Text(session.transcript.isEmpty ? placeholder : session.transcript)
                            .font(VF.bodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Press ⌘R to start a long-form capture.")
                        .font(VF.bodyFont).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(VF.spacingLarge)
        }
        .onChange(of: sessionService.currentSession?.transcript) { _, new in
            // Keep the editor in sync when the transcript changes externally
            // (smart action / undo) and we're not mid-edit.
            if !editing { draft = new ?? "" }
        }
        .onAppear { draft = sessionService.currentSession?.transcript ?? "" }
    }

    private func commitEdit() {
        let after = draft
        guard after != baseline else { return }
        sessionService.setTranscript(after)
        onEditCommit?(baseline, after)
    }

    // crumbs(_:) and placeholder unchanged
}
```

- [ ] **Step 2: Build + manual verify**

Run: `swift build`. Then in the app: after a capture, stop to enter review, edit a word in the transcript, click away. Expected: edit persists (visible after reopening), and (once Phase B lands) the correction is learned.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/Cockpit/CockpitTranscriptView.swift
git commit -m "feat(cockpit): editable review transcript + focus-loss edit-commit hook"
```

---

# Phase B — Personal dictionary (apply + learn)

Self-contained Layer 1 subsystem. Ships as its own PR. Fixes Whisper mangling legal/governance terms and learns from your review edits.

## Task B1: DictionaryEntry model

**Files:**
- Modify: `Sources/VoxFlowApp/Models/AppModels.swift` (near the other cockpit types, after `AppliedAction` ~`:758`)

- [ ] **Step 1: Add the model**

```swift
struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    let wrong: String        // recognized (incorrect) form, e.g. "iso forty two thousand one"
    let right: String        // intended form, e.g. "ISO 42001"
    var context: String?     // optional disambiguation note
    let learnedAt: Date
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Models/AppModels.swift
git commit -m "feat(dictionary): add DictionaryEntry model"
```

## Task B2: DictionaryStore — persistence + seed

**Files:**
- Create: `Sources/VoxFlowApp/Services/DictionaryStore.swift`
- Test: `Tests/VoxFlowAppTests/DictionaryStoreTests.swift`

Mirrors `LongFormSessionService` persistence (JSONEncoder `.prettyPrinted/.sortedKeys/.iso8601`, atomic write, injectable URL + `SessionClock`).

- [ ] **Step 1: Write the failing persistence test**

Create `Tests/VoxFlowAppTests/DictionaryStoreTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }

    func test_add_persists_and_reloads() {
        let url = tmpURL()
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "wherefor", right: "WHEREFORE", context: nil)
        let reloaded = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.entries.map(\.right), ["WHEREFORE"])
    }

    func test_seed_on_first_run_only() {
        let url = tmpURL()
        let first = DictionaryStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertFalse(first.entries.isEmpty)               // seeded
        let count = first.entries.count
        let second = DictionaryStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertEqual(second.entries.count, count)         // not re-seeded
    }

    func test_remove() {
        let url = tmpURL()
        let store = DictionaryStore(fileURL: url, seedOnFirstRun: false)
        store.add(wrong: "a", right: "A", context: nil)
        let id = store.entries[0].id
        store.remove(id)
        XCTAssertTrue(store.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DictionaryStoreTests`
Expected: FAIL — `DictionaryStore` not defined.

- [ ] **Step 3: Implement the store**

Create `Sources/VoxFlowApp/Services/DictionaryStore.swift`:

```swift
import Foundation
import os

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var entries: [DictionaryEntry] = []

    private let fileURL: URL
    private let clock: SessionClock
    private let log = Logger(subsystem: "local.voxflow.app", category: "DictionaryStore")

    /// Seed terms applied once on first run if no file exists.
    static let seedTerms: [(String, String)] = [
        ("iso forty two thousand one", "ISO 42001"),
        ("a i g p", "AIGP"), ("c i p t", "CIPT"),
        ("gdpr", "GDPR"), ("hipaa", "HIPAA"),
        ("wherefor", "WHEREFORE"), ("r c w", "RCW")
    ]

    init(fileURL: URL, clock: SessionClock = SystemClock(), seedOnFirstRun: Bool = true) {
        self.fileURL = fileURL
        self.clock = clock
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let loaded = Self.load(from: fileURL) {
            entries = loaded
        } else if seedOnFirstRun {
            entries = Self.seedTerms.map {
                DictionaryEntry(wrong: $0.0, right: $0.1, context: "seed", learnedAt: clock.currentTime())
            }
            save()
        }
    }

    func add(wrong: String, right: String, context: String?) {
        entries.append(DictionaryEntry(wrong: wrong, right: right, context: context, learnedAt: clock.currentTime()))
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
        } catch { log.error("save failed: \(error.localizedDescription)") }
    }

    private static func load(from url: URL) -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([DictionaryEntry].self, from: data)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter DictionaryStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/DictionaryStore.swift Tests/VoxFlowAppTests/DictionaryStoreTests.swift
git commit -m "feat(dictionary): DictionaryStore — JSON persistence + first-run seed"
```

## Task B3: Apply pass (whole-word, case-preserving replacement)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/DictionaryStore.swift`
- Modify: `Tests/VoxFlowAppTests/DictionaryStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `DictionaryStoreTests`:

```swift
func test_applyCorrections_whole_word_case_preserving() {
    let entries = [
        DictionaryEntry(wrong: "wherefor", right: "WHEREFORE", context: nil, learnedAt: .init()),
        DictionaryEntry(wrong: "gdpr", right: "GDPR", context: nil, learnedAt: .init())
    ]
    let out = DictionaryStore.applyCorrections("the wherefor clause under gdpr applies", using: entries)
    XCTAssertEqual(out, "the WHEREFORE clause under GDPR applies")
}

func test_applyCorrections_does_not_touch_substrings() {
    let entries = [DictionaryEntry(wrong: "art", right: "ART", context: nil, learnedAt: .init())]
    let out = DictionaryStore.applyCorrections("smart parties", using: entries)
    XCTAssertEqual(out, "smart parties")   // "art" inside "smart"/"parties" untouched
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DictionaryStoreTests`
Expected: FAIL — `applyCorrections` not defined.

- [ ] **Step 3: Implement the pure function + instance wrapper**

Add to `DictionaryStore`:

```swift
/// Whole-word, case-insensitive match; replacement substituted verbatim
/// (the `right` form already carries intended casing, e.g. "GDPR").
static func applyCorrections(_ text: String, using entries: [DictionaryEntry]) -> String {
    var result = text
    for entry in entries where !entry.wrong.isEmpty {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: entry.wrong) + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
        let range = NSRange(result.startIndex..., in: result)
        result = re.stringByReplacingMatches(
            in: result, range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: entry.right))
    }
    return result
}

func apply(to text: String) -> String { Self.applyCorrections(text, using: entries) }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter DictionaryStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/DictionaryStore.swift Tests/VoxFlowAppTests/DictionaryStoreTests.swift
git commit -m "feat(dictionary): whole-word case-preserving apply pass"
```

## Task B4: Wire the apply pass into chunk ingestion

**Files:**
- Modify: `Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift`
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (coordinator construction)

- [ ] **Step 1: Add an optional dictionary to the coordinator**

Add `private let dictionary: DictionaryStore?` to `CockpitCaptureCoordinator`, accept it in `init` (default `nil`), and in `flushNow()` change the append line to apply corrections first:

```swift
let corrected = dictionary?.apply(to: text) ?? text
session.appendChunk(corrected)
```

- [ ] **Step 2: Update the test to assert correction is applied**

Add to `CockpitCaptureCoordinatorTests` a test injecting a `DictionaryStore` (temp URL, `seedOnFirstRun: false`) with `add(wrong: "wherefor", right: "WHEREFORE", context: nil)`, set `transcriber.nextText = "the wherefor clause"`, flush, assert transcript == `"the WHEREFORE clause"`.

- [ ] **Step 3: Construct with the dictionary in AppCoordinator**

Add a `cockpitDictionary` lazy property (`DictionaryStore(fileURL: appSupport.appendingPathComponent("dictionary.json"))`) and pass it into the `CockpitCaptureCoordinator(...)` initializer.

- [ ] **Step 4: Run + commit**

Run: `swift test --filter CockpitCaptureCoordinatorTests` → PASS.
```bash
git add Sources/VoxFlowApp/Services/CockpitCaptureCoordinator.swift Sources/VoxFlowApp/AppCoordinator.swift Tests/VoxFlowAppTests/CockpitCaptureCoordinatorTests.swift
git commit -m "feat(dictionary): apply corrections on the long-form chunk ingestion path"
```

## Task B5: Learning diff (1:1 substitution detection)

**Files:**
- Modify: `Sources/VoxFlowApp/Services/DictionaryStore.swift`
- Modify: `Tests/VoxFlowAppTests/DictionaryStoreTests.swift`

Conservative heuristic: tokenize before/after on whitespace; only when token counts are **equal**, record each position where exactly one token changed as a `(wrong→right)` pair (punctuation stripped). Unequal counts (insertions/deletions) are skipped — too ambiguous for reliable learning.

- [ ] **Step 1: Write the failing test**

```swift
func test_learn_single_word_substitution() {
    let pairs = DictionaryStore.learn(before: "the wherefor clause", after: "the WHEREFORE clause")
    XCTAssertEqual(pairs.count, 1)
    XCTAssertEqual(pairs[0].wrong, "wherefor")
    XCTAssertEqual(pairs[0].right, "WHEREFORE")
}

func test_learn_skips_when_token_count_differs() {
    let pairs = DictionaryStore.learn(before: "the clause", after: "the WHEREFORE clause")
    XCTAssertTrue(pairs.isEmpty)
}

func test_learn_strips_trailing_punctuation() {
    let pairs = DictionaryStore.learn(before: "cited rcw.", after: "cited RCW.")
    XCTAssertEqual(pairs.map(\.right), ["RCW"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DictionaryStoreTests` → FAIL (`learn` not defined).

- [ ] **Step 3: Implement**

```swift
struct LearnedPair: Equatable { let wrong: String; let right: String }

static func learn(before: String, after: String) -> [LearnedPair] {
    let b = before.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let a = after.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard b.count == a.count, !b.isEmpty else { return [] }
    let punct = CharacterSet.punctuationCharacters
    var pairs: [LearnedPair] = []
    for (bw, aw) in zip(b, a) where bw != aw {
        let wrong = bw.trimmingCharacters(in: punct)
        let right = aw.trimmingCharacters(in: punct)
        if !wrong.isEmpty, !right.isEmpty, wrong.lowercased() != right.lowercased() || wrong != right {
            pairs.append(LearnedPair(wrong: wrong, right: right))
        }
    }
    return pairs
}

/// Learn from a review edit and persist new entries (skips dupes by wrong+right).
func learnFromEdit(before: String, after: String) {
    for p in Self.learn(before: before, after: after) {
        let exists = entries.contains { $0.wrong == p.wrong && $0.right == p.right }
        if !exists { add(wrong: p.wrong, right: p.right, context: "learned") }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter DictionaryStoreTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/DictionaryStore.swift Tests/VoxFlowAppTests/DictionaryStoreTests.swift
git commit -m "feat(dictionary): learn 1:1 word substitutions from review edits"
```

## Task B6: Wire learning into the transcript edit-commit

**Files:**
- Modify: `Sources/VoxFlowApp/Views/CockpitWindowView.swift` (where `CockpitTranscriptView` is constructed)

- [ ] **Step 1: Pass the learning hook**

Where `CockpitTranscriptView(sessionService:)` is built, add the `onEditCommit` closure wired to the dictionary:

```swift
CockpitTranscriptView(sessionService: sessionService) { before, after in
    coordinator.cockpitDictionary.learnFromEdit(before: before, after: after)
}
```

- [ ] **Step 2: Build + manual verify**

Run: `swift build`. In-app: record → review → fix a mangled term → click away → reopen Settings Dictionary (Task B7) and confirm the learned pair is present.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/CockpitWindowView.swift
git commit -m "feat(dictionary): learn corrections from cockpit review edits"
```

## Task B7: Settings → Dictionary section

**Files:**
- Modify: `Sources/VoxFlowApp/Views/SettingsView.swift` (add a `Section("Dictionary")` following the existing `Form { Section(...) }` pattern, e.g. after the "Dictation" section ~`:256`)

- [ ] **Step 1: Add the section**

`SettingsView` must receive the `DictionaryStore` (pass `coordinator.cockpitDictionary` where `SettingsView` is constructed). Add:

```swift
Section("Dictionary") {
    if dictionary.entries.isEmpty {
        Text("No corrections yet. Fix a mangled term in the cockpit review to teach VoxFlow.")
            .font(VF.captionFont).foregroundStyle(.secondary)
    }
    ForEach(dictionary.entries) { entry in
        HStack {
            Text(entry.wrong).foregroundStyle(.secondary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(entry.right)
            Spacer()
            Button(role: .destructive) { dictionary.remove(entry.id) } label: {
                Image(systemName: "trash")
            }.buttonStyle(.borderless)
        }
    }
    HStack {
        TextField("recognized", text: $newWrong)
        Image(systemName: "arrow.right")
        TextField("correct", text: $newRight)
        Button("Add") {
            guard !newWrong.isEmpty, !newRight.isEmpty else { return }
            dictionary.add(wrong: newWrong, right: newRight, context: "manual")
            newWrong = ""; newRight = ""
        }
    }
}
```
(Declare `@ObservedObject var dictionary: DictionaryStore` and `@State private var newWrong = ""`, `@State private var newRight = ""` on `SettingsView`.)

- [ ] **Step 2: Build + manual verify**

Run: `swift build`. Open Settings → Dictionary: add/delete an entry; confirm it persists across relaunch.

- [ ] **Step 3: Commit**

```bash
git add Sources/VoxFlowApp/Views/SettingsView.swift
git commit -m "feat(dictionary): Settings → Dictionary section (list/add/delete)"
```

## Task B8: Side-panel Dictionary card

**Files:**
- Modify: `Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift` (the file comment already reserves "Layer 1: + Dictionary card")

- [ ] **Step 1: Add the card following the existing card pattern**

Add `@ObservedObject var dictionary: DictionaryStore` to the view, insert `dictionarySection` between `targetSection` and `recentSection` in `body`, and:

```swift
private var dictionarySection: some View {
    VStack(alignment: .leading, spacing: 6) {
        sectionTitle("Dictionary")
        let recent = dictionary.entries.suffix(3).reversed()
        if recent.isEmpty {
            Text("No learned terms").font(VF.captionFont).foregroundStyle(.secondary)
        } else {
            ForEach(Array(recent)) { entry in
                HStack(spacing: VF.spacingSmall) {
                    Text(entry.wrong).font(VF.microFont).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(entry.right).font(VF.captionFont)
                    Spacer()
                }
                .padding(VF.spacingSmall)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
            }
        }
    }
}
```
Update the `CockpitSidePanelView(...)` construction site to pass `dictionary: coordinator.cockpitDictionary`.

- [ ] **Step 2: Build + manual verify + commit**

Run: `swift build`. Confirm learned terms appear in the cockpit side panel.
```bash
git add Sources/VoxFlowApp/Views/Cockpit/CockpitSidePanelView.swift
git commit -m "feat(dictionary): side-panel Dictionary card (recent learned terms)"
```

## Phase B acceptance

- [ ] `swift test` green (new `DictionaryStoreTests` + updated `CockpitCaptureCoordinatorTests`)
- [ ] Dictate a seeded term (e.g. "GDPR") → corrected in transcript
- [ ] Edit a mangled term in review → appears in Settings → Dictionary and side-panel card
- [ ] `~/Library/Application Support/VoxFlow/dictionary.json` persists across relaunch

---

# Phase C — Notion integration (OUTLINE — needs its own detailed plan)

> Each of C/D/E is an independent shippable subsystem. Expand to full TDD detail when reached. Do NOT start before Phase B ships and is dogfooded.

**Decision:** reuse the Notion MCP. The backend becomes an **MCP client** that spawns the Notion MCP server as a managed subprocess.

**⚠️ Lead with a spike (C0):** prove the Notion MCP server can run **headless** (no Claude running) with credentials supplied via env/config, and that the backend can complete the MCP handshake + a `search` + `append-block` call. **If the spike fails** (auth requires interactive OAuth via Claude), fall back to the design-doc's original approach — backend-proxied Notion REST API with an integration token in Keychain. Budget the spike before committing to the MCP path.

**Likely file structure:**
- `backend/app/integrations/notion_mcp.py` — MCP client: subprocess lifecycle, JSON-RPC over stdio, `search_pages`, `append_blocks`
- `backend/app/api/endpoints.py` — `POST /v1/notion/search`, `POST /v1/notion/append` (rate-limit + consent patterns honored)
- `backend/app/schemas.py` — `NotionSearchRequest/Response`, `NotionAppendRequest/Response`
- `Sources/VoxFlowApp/Services/BackendAPIClient.swift` — `notionSearch`, `notionAppend` methods
- Cockpit target picker — add "Notion · \<page\>" entries; append-at-cursor behavior
- `KeychainService` — Notion credentials (never UserDefaults)

**Task sketch:** C0 headless-MCP spike → C1 backend MCP client + tests (mock MCP server) → C2 `/v1/notion/*` endpoints → C3 Swift client methods → C4 target-picker "Notion · page" entries → C5 wire smart-action → Notion append → C6 Settings → Integrations → Notion.

**Risks:** headless MCP auth (primary); subprocess lifecycle/zombies (use `BackendProcessManager`-style supervision); Notion API rate limits; token storage. All MCP calls must be timeout-bounded.

# Phase D — Voice snippets (OUTLINE)

Named text expansions triggered by voice keyword (`disclaimer`, `sigoff`, `boilerplate`, `addr`, `bcc-paralegals`).

**File structure:** `Sources/VoxFlowApp/Models/AppModels.swift` (`VoiceSnippet` + `SnippetScope` enum `.global/.longFormOnly/.quickOnly`), `Sources/VoxFlowApp/Services/SnippetStore.swift` (mirror `DictionaryStore`), `VoiceCommandRouter.swift` (resolve snippet triggers → expansion), Settings → Snippets table.

**Task sketch:** D1 `VoiceSnippet`/`SnippetScope` models → D2 `SnippetStore` (JSON, seed) + tests → D3 trigger pipeline (keyword → expansion inserted at cursor) + scope gating + tests → D4 Settings → Snippets UI.

**Note:** `VoiceCommandRouter.parse` is single-keyword by design (Layer 0 constraint); snippet triggers extend the keyword set — keep the parser unambiguous (reserved meta-words `cancel`/`undo`/`insert`/`copy` win over snippet triggers).

# Phase E — Workflow chains (OUTLINE — lowest priority, most speculative)

Linear (no conditional logic) multi-step automations, e.g. "Memo to Notion" = capture → memo action → append to Notion page.

**File structure:** `AppModels.swift` (`WorkflowChain`, `ChainStep` enum `.capture(mode:)/.action(actionId:)/.insert(targetHint:)`, plus `CaptureMode`/`TargetHint`), `Sources/VoxFlowApp/Services/ChainStore.swift` + `ChainExecutor.swift`, `⌘K` palette invocation by name, Settings → Chains UI.

**Task sketch:** E1 models → E2 `ChainStore` (JSON) + tests → E3 `ChainExecutor` (sequential step runner over existing services) + tests → E4 `⌘K` typed-name invocation → E5 Settings → Chains UI.

**Dependency:** E5/E4's most valuable chain ("memo → Notion") needs Phase C. Build chains last.

---

## Sequencing & PR strategy

```
Phase 0 (close-out)  →  Phase A (L0 capture keystone)  →  Phase B (dictionary)
                                                              ↓
                                            Phase D (snippets, parallel-safe)
                                                              ↓
                              Phase C (Notion, spike-gated)  →  Phase E (chains)
```

- One PR per phase (A, B, C, D, E). Phase 0 lands as small doc/ops commits.
- Each phase keeps `swift test` + `pytest backend/tests` green before merge.
- Use `superpowers:finishing-a-development-branch` to integrate each phase.

## Open questions deferred to per-phase plans

- **Chunk flush interval** (Phase A): 5s default; the stop-restart segmentation drops a small audio gap and may split words at boundaries — tune interval, or later add a rolling-buffer API to `AudioCaptureService` if word-splitting hurts quality.
- **Learning aggressiveness** (Phase B): 1:1 substitution only; revisit if too conservative (misses multi-word fixes) or too noisy (learns typos).
- **Notion auth headless** (Phase C): the spike (C0) decides MCP-client vs REST-token fallback.
- **Chip promotion threshold** (3) and MRU (30) — tune from real usage once capture works.
