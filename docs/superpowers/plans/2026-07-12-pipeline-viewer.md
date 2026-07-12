# Pipeline Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface per-capture pipeline provenance (mode, served-by, target, duration, confidence, reject reason) from `insertions.jsonl` in two persistent UI surfaces: a last-capture row in the command palette and a Recent Captures section in the Dashboard.

**Architecture:** Read model over the existing `InsertionAuditLog` JSONL event log. A read-only `@MainActor` store parses the file tail into typed receipts; two views observe it and trigger refreshes on view events. Zero changes to any capture, insert, or audit write path.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI, XCTest. macOS 14+ deployment target.

**Spec:** `docs/superpowers/specs/2026-07-12-pipeline-viewer-design.md` (approved).

## Global Constraints

- Swift 6.2 strict concurrency: new store is `@MainActor`; use `Date.ISO8601FormatStyle` (Sendable struct) for timestamp parsing, NOT `ISO8601DateFormatter` (non-Sendable class; a `static let` of it will not compile in a nonisolated context).
- All view styling through `VFDesignTokens` (`VF.*`). Never `.font(.system(size:))` or `Color.gray.opacity(...)` in `Sources/VoxFlowApp/Views/` (repo rule).
- Do NOT touch any capture/insert/audit write path. The only production files modified are `AppCoordinator.swift` (one lazy property + one construction argument), `VoxFlowLocalApp.swift` (one construction argument), `CommandPaletteView.swift`, `DashboardWindowView.swift`.
- Tests must not construct real system-touching services (repo seam rule). File IO in tests is confined to `FileManager.default.temporaryDirectory` fixtures (pattern: `InsertionAuditLogTests.swift`).
- Commits: imperative subject, detailed body, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Work on branch `feature/pipeline-viewer` (already created; spec committed as `d60b83c`).
- The receipt `source` labels contain an em dash (`—`, U+2014) surrounded by spaces as the app-label separator, and ` · ` (U+00B7) between tokens. Copy the string literals from this plan exactly.
- Suite baseline before this work: 643 Swift tests green (`swift test`).

---

### Task 1: CaptureReceipt model + SourceLabel parser

**Files:**
- Create: `Sources/VoxFlowApp/Services/CaptureReceipt.swift`
- Test: `Tests/VoxFlowAppTests/CaptureReceiptTests.swift`
- Modify: `Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift` (add ONE round-trip pinning test)

**Interfaces:**
- Consumes: nothing (leaf task).
- Produces:
  - `struct CaptureReceipt: Equatable, Decodable` with `enum Event: String { case insert, reject }` and stored properties `event: Event`, `ts: Date`, `text: String?`, `source: String?`, `target: String?`, `confidence: Double?`, `audioSeconds: Double?`, `rms: Double?`, `peakAmplitude: Double?`, `reason: String?`, `audioFile: String?`, plus computed `sourceLabel: SourceLabel`.
  - `struct SourceLabel: Equatable` with `tokens: [String]`, `appLabel: String?`, and `static func parse(_ source: String) -> SourceLabel`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VoxFlowAppTests/CaptureReceiptTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

/// Read-model side of InsertionAuditLog: one JSONL line -> one typed receipt.
/// Decoding is lenient by design — the schema grew over time, so every field
/// beyond event/ts is optional and type mismatches nil the field, not the line.
final class CaptureReceiptTests: XCTestCase {

    private func decode(_ json: String) -> CaptureReceipt? {
        try? JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    func testDecodesInsertLine() {
        let r = decode(#"{"event":"insert","ts":"2026-07-12T19:00:00Z","text":"hello world","source":"Inserted (light · rules — app)","target":"Notes","confidence":0.91,"audio_seconds":3.4}"#)
        XCTAssertEqual(r?.event, .insert)
        XCTAssertEqual(r?.text, "hello world")
        XCTAssertEqual(r?.target, "Notes")
        XCTAssertEqual(r?.confidence, 0.91)
        XCTAssertEqual(r?.audioSeconds, 3.4)
    }

    func testDecodesRejectLineWithAudioFile() {
        let r = decode(#"{"event":"reject","ts":"2026-07-09T17:20:44Z","text":"","reason":"empty","confidence":0.0,"audio_seconds":0.86,"source":"quick_dictation","rms":0.015,"audio_file":"/tmp/reject.wav"}"#)
        XCTAssertEqual(r?.event, .reject)
        XCTAssertEqual(r?.reason, "empty")
        XCTAssertEqual(r?.rms, 0.015)
        XCTAssertEqual(r?.audioFile, "/tmp/reject.wav")
    }

    /// The writer sanitizes NaN/Inf to the string "non-finite" so the record
    /// survives; the reader must nil that FIELD without dropping the LINE.
    func testNonFiniteSentinelNilsTheFieldNotTheLine() {
        let r = decode(#"{"event":"reject","ts":"2026-07-09T17:20:44Z","reason":"empty","rms":"non-finite"}"#)
        XCTAssertNotNil(r)
        XCTAssertNil(r?.rms)
        XCTAssertEqual(r?.reason, "empty")
    }

    func testMissingTsFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"insert","text":"hi"}"#))
    }

    func testUnknownEventFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"banana","ts":"2026-07-12T19:00:00Z"}"#))
    }

    func testMalformedJSONFailsTheLine() {
        XCTAssertNil(decode(#"{"event":"insert","ts":"#))
    }

    func testFractionalSecondsTimestampParses() {
        let r = decode(#"{"event":"insert","ts":"2026-07-12T19:00:00.123Z","text":"x"}"#)
        XCTAssertNotNil(r?.ts)
    }
}

/// Structured view of the audit `source` display label.
final class SourceLabelTests: XCTestCase {

    func testLightRulesApp() {
        let l = SourceLabel.parse("Inserted (light · rules — app)")
        XCTAssertEqual(l.tokens, ["light", "rules"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testPolishModelTerminal() {
        let l = SourceLabel.parse("Inserted (polish · gemma4:e2b-mlx — Terminal)")
        XCTAssertEqual(l.tokens, ["polish", "gemma4:e2b-mlx"])
        XCTAssertEqual(l.appLabel, "Terminal")
    }

    func testRawNoProvenance() {
        let l = SourceLabel.parse("Inserted (raw — app)")
        XCTAssertEqual(l.tokens, ["raw"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testLegacyLightWithoutProvenanceToken() {
        let l = SourceLabel.parse("Inserted (light — app)")
        XCTAssertEqual(l.tokens, ["light"])
        XCTAssertEqual(l.appLabel, "app")
    }

    /// Tone joins the mode token with ", " (not " · ") — it must stay fused
    /// to the mode token, not become its own chip.
    func testToneVariantStaysFusedToModeToken() {
        let l = SourceLabel.parse("Inserted (light, friendly · rules — app)")
        XCTAssertEqual(l.tokens, ["light, friendly", "rules"])
        XCTAssertEqual(l.appLabel, "app")
    }

    func testNonInsertSourcePassesThroughAsSingleToken() {
        let l = SourceLabel.parse("quick_dictation")
        XCTAssertEqual(l.tokens, ["quick_dictation"])
        XCTAssertNil(l.appLabel)
    }

    func testEmptySourceYieldsNoTokens() {
        let l = SourceLabel.parse("")
        XCTAssertEqual(l.tokens, [])
        XCTAssertNil(l.appLabel)
    }

    /// Documents the label grammar inline: mirrors the interpolation in
    /// DictationWorkflowCoordinator.autoInsertOrReview (currently line ~271):
    ///   "Inserted (\(mode)\(toneLabel)\(provenanceTag) — \(appLabel))"
    /// The REAL pinning (real code path) is the round-trip test added to
    /// DictationWorkflowCoordinatorTests below.
    func testPinsDictationWorkflowLabelFormat() {
        let mode = "light"
        let toneLabel = ", friendly"
        let provenanceTag = " · rules"
        let appLabel = "app"
        let source = "Inserted (\(mode)\(toneLabel)\(provenanceTag) — \(appLabel))"
        let parsed = SourceLabel.parse(source)
        XCTAssertEqual(parsed.tokens, ["light, friendly", "rules"])
        XCTAssertEqual(parsed.appLabel, "app")
    }
}
```

Also append ONE test to the existing `Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift` (place it directly after `testAutoInsertSuffixCarriesModelProvenance`, ~line 530; it reuses that file's existing `makeSUT()` and `DictationMockURLProtocol` fixtures — do not create new fixtures):

```swift
    /// Round-trip pinning for the pipeline viewer: the statusSuffix built by
    /// the REAL auto-insert code path (which becomes the audit `source`) must
    /// parse into structured chips via SourceLabel.parse. If the label format
    /// in autoInsertOrReview drifts, this fails — the writer and the viewer's
    /// parser move together or not at all.
    @MainActor func testAutoInsertSuffixRoundTripsThroughSourceLabelParse() async throws {
        let (sut, state, textInsertion, _) = makeSUT()
        state.backendReadiness.readyForDictation = true

        let polishResponse = """
        {"output_text": "polished by gemma", "mode_applied": "polish", "guardrail_triggered": false, "served_by": "ollama", "model_id": "gemma4:e2b-mlx"}
        """.data(using: .utf8)!
        DictationMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, polishResponse)
        }

        let request = DictationWorkflowRequest(
            sessionID: "prov-roundtrip", rawText: "clean me", providerMode: .localOnly,
            consentToken: nil, allowRaw: false, toneStyle: .neutral,
            insertBehavior: .autoInsertPolish, sttBackend: .whisperKit,
            lastTranscriptionConfidence: 0.9, targetApp: nil)

        try await sut.processDictation(request) { _, _, _ in }

        let suffix = try XCTUnwrap(textInsertion.statusSuffix)
        let parsed = SourceLabel.parse(suffix)
        XCTAssertEqual(parsed.tokens, ["polish", "gemma4:e2b-mlx"],
                       "suffix was \(suffix)")
        XCTAssertEqual(parsed.appLabel, "app")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureReceiptTests 2>&1 | tail -5`
Expected: compile FAILURE with `cannot find 'CaptureReceipt' in scope` (a new-type TDD cycle fails at compile, not assert).

- [ ] **Step 3: Write the implementation**

Create `Sources/VoxFlowApp/Services/CaptureReceipt.swift`:

```swift
import Foundation

/// One parsed line of ~/Library/Logs/VoxFlow/insertions.jsonl — the read-model
/// side of InsertionAuditLog, for the pipeline viewer. Decoding is deliberately
/// lenient: the schema grew over time, so every field beyond event/ts is
/// optional, and a value that doesn't match its expected type (e.g. the
/// writer's "non-finite" sentinel in a numeric slot) decodes to nil instead of
/// failing the whole line.
struct CaptureReceipt: Equatable {
    enum Event: String { case insert, reject }

    let event: Event
    let ts: Date
    let text: String?
    let source: String?
    let target: String?
    let confidence: Double?
    let audioSeconds: Double?
    let rms: Double?
    let peakAmplitude: Double?
    let reason: String?
    let audioFile: String?

    var sourceLabel: SourceLabel { SourceLabel.parse(source ?? "") }
}

extension CaptureReceipt: Decodable {
    private enum CodingKeys: String, CodingKey {
        case event, ts, text, source, target, confidence, reason, rms
        case audioSeconds = "audio_seconds"
        case peakAmplitude = "peak_amplitude"
        case audioFile = "audio_file"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // event + ts are the only hard requirements; a line without them is
        // unattributable and the store skips it.
        guard let rawEvent = try? c.decode(String.self, forKey: .event),
              let event = Event(rawValue: rawEvent) else {
            throw DecodingError.dataCorruptedError(
                forKey: .event, in: c, debugDescription: "missing or unknown event")
        }
        guard let tsString = try? c.decode(String.self, forKey: .ts),
              let ts = Self.parseTimestamp(tsString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .ts, in: c, debugDescription: "missing or unparseable ts")
        }
        self.event = event
        self.ts = ts
        text = try? c.decode(String.self, forKey: .text)
        source = try? c.decode(String.self, forKey: .source)
        target = try? c.decode(String.self, forKey: .target)
        confidence = try? c.decode(Double.self, forKey: .confidence)
        audioSeconds = try? c.decode(Double.self, forKey: .audioSeconds)
        rms = try? c.decode(Double.self, forKey: .rms)
        peakAmplitude = try? c.decode(Double.self, forKey: .peakAmplitude)
        reason = try? c.decode(String.self, forKey: .reason)
        audioFile = try? c.decode(String.self, forKey: .audioFile)
    }

    // FormatStyle is a Sendable struct, so these are safe as static lets under
    // strict concurrency (ISO8601DateFormatter, a class, would not be).
    private static let isoPlain = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func parseTimestamp(_ s: String) -> Date? {
        (try? isoPlain.parse(s)) ?? (try? isoFractional.parse(s))
    }
}

/// Structured view of an audit receipt's `source` display label.
/// "Inserted (light · rules — app)" -> tokens ["light", "rules"], appLabel "app".
/// Non-insert sources ("quick_dictation") pass through as a single token so
/// unknown formats render fine instead of breaking.
struct SourceLabel: Equatable {
    let tokens: [String]
    let appLabel: String?

    static func parse(_ source: String) -> SourceLabel {
        guard source.hasPrefix("Inserted ("), source.hasSuffix(")") else {
            return SourceLabel(tokens: source.isEmpty ? [] : [source], appLabel: nil)
        }
        let inner = String(source.dropFirst("Inserted (".count).dropLast(1))
        let head: String
        let app: String?
        // App label is everything after the LAST " — " (em dash); tokens keep
        // their ", "-joined tone suffixes fused (tone is not a separate chip).
        if let range = inner.range(of: " — ", options: .backwards) {
            head = String(inner[..<range.lowerBound])
            app = String(inner[range.upperBound...])
        } else {
            head = inner
            app = nil
        }
        let tokens = head.components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return SourceLabel(tokens: tokens, appLabel: app)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "CaptureReceiptTests|SourceLabelTests" 2>&1 | tail -5`
Expected: `Executed 15 tests, with 0 failures`

Run: `swift test --filter DictationWorkflowCoordinatorTests 2>&1 | tail -3`
Expected: 0 failures (existing tests plus the new round-trip test).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/CaptureReceipt.swift Tests/VoxFlowAppTests/CaptureReceiptTests.swift Tests/VoxFlowAppTests/DictationWorkflowCoordinatorTests.swift
git commit -m "feat: CaptureReceipt read model + source-label parser

Lenient per-line decoder over insertions.jsonl receipts (event/ts required,
everything else optional, non-finite sentinels nil the field not the line)
plus a parser that splits the 'Inserted (mode · provenance — app)' display
label into chips. Round-trip test drives the REAL auto-insert path
(DictationWorkflowCoordinator fixtures) and parses the captured statusSuffix,
so writer/parser drift fails loudly.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: InsertionReceiptStore (read-only JSONL tail reader)

**Files:**
- Create: `Sources/VoxFlowApp/Services/InsertionReceiptStore.swift`
- Test: `Tests/VoxFlowAppTests/InsertionReceiptStoreTests.swift`

**Interfaces:**
- Consumes: `CaptureReceipt` (Task 1), `InsertionAuditLog.defaultFileURL` (existing, `nonisolated static var` on `InsertionAuditLog`).
- Produces:
  - `@MainActor final class InsertionReceiptStore: ObservableObject`
  - `init(fileURL: URL = InsertionAuditLog.defaultFileURL, maxReceipts: Int = 50, maxTailBytes: Int = 262_144)`
  - `@Published private(set) var receipts: [CaptureReceipt]` (newest first, capped at `maxReceipts`)
  - `var latest: CaptureReceipt?`
  - `func refresh()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VoxFlowAppTests/InsertionReceiptStoreTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

/// Read-only view over InsertionAuditLog's JSONL for the pipeline viewer.
/// Same temp-dir fixture pattern as InsertionAuditLogTests; the store never
/// writes, so no failure mode can touch dictation data.
@MainActor
final class InsertionReceiptStoreTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-receipts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("insertions.jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// One receipt line with a deterministic second-of-minute in ts and a text.
    private func line(second: Int, text: String) -> String {
        let ss = String(format: "%02d", second)
        return #"{"event":"insert","ts":"2026-07-12T19:00:\#(ss)Z","text":"\#(text)","source":"Inserted (light · rules — app)"}"#
    }

    private func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsNewestFirstAndCapsAtMaxReceipts() throws {
        try write((0..<5).map { line(second: $0, text: "t\($0)") }, to: fileURL)
        let store = InsertionReceiptStore(fileURL: fileURL, maxReceipts: 3)
        store.refresh()
        XCTAssertEqual(store.receipts.count, 3)
        XCTAssertEqual(store.receipts.first?.text, "t4")
        XCTAssertEqual(store.receipts.last?.text, "t2")
        XCTAssertEqual(store.latest?.text, "t4")
    }

    func testSkipsMalformedLines() throws {
        try write([line(second: 0, text: "good"), "{not json", line(second: 2, text: "also good")], to: fileURL)
        let store = InsertionReceiptStore(fileURL: fileURL)
        store.refresh()
        XCTAssertEqual(store.receipts.map(\.text), ["also good", "good"])
    }

    func testMissingFileYieldsEmpty() {
        let store = InsertionReceiptStore(fileURL: fileURL)
        store.refresh()
        XCTAssertEqual(store.receipts, [])
        XCTAssertNil(store.latest)
    }

    /// When the main file holds fewer than maxReceipts lines, the .1.jsonl
    /// rotation backup fills in older history (writer rotates at ~1 MB).
    func testRotationBackupFillsOlderHistory() throws {
        let backupURL = tempDir.appendingPathComponent("insertions.1.jsonl")
        try write((0..<3).map { line(second: $0, text: "old\($0)") }, to: backupURL)
        try write((10..<12).map { line(second: $0, text: "new\($0)") }, to: fileURL)
        let store = InsertionReceiptStore(fileURL: fileURL, maxReceipts: 50)
        store.refresh()
        XCTAssertEqual(store.receipts.count, 5)
        XCTAssertEqual(store.receipts.first?.text, "new11")
        XCTAssertEqual(store.receipts.last?.text, "old0")
    }

    func testRefreshPicksUpAppendedLinesAndIsStableWhenUnchanged() throws {
        try write([line(second: 0, text: "first")], to: fileURL)
        let store = InsertionReceiptStore(fileURL: fileURL)
        store.refresh()
        XCTAssertEqual(store.receipts.count, 1)

        let before = store.receipts
        store.refresh()
        XCTAssertEqual(store.receipts, before)

        try write([line(second: 0, text: "first"), line(second: 1, text: "second")], to: fileURL)
        store.refresh()
        XCTAssertEqual(store.receipts.first?.text, "second")
        XCTAssertEqual(store.receipts.count, 2)
    }

    /// A tail window smaller than the file must still return the NEWEST lines
    /// and drop the partial first line the mid-file seek lands in.
    func testSmallTailWindowKeepsNewestLines() throws {
        let lines = (0..<10).map { line(second: $0, text: "padpadpadpad\($0)") }
        try write(lines, to: fileURL)
        let store = InsertionReceiptStore(fileURL: fileURL, maxReceipts: 50, maxTailBytes: 300)
        store.refresh()
        XCTAssertGreaterThan(store.receipts.count, 0)
        XCTAssertLessThan(store.receipts.count, 10)
        XCTAssertEqual(store.receipts.first?.text, "padpadpadpad9")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter InsertionReceiptStoreTests 2>&1 | tail -5`
Expected: compile FAILURE with `cannot find 'InsertionReceiptStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VoxFlowApp/Services/InsertionReceiptStore.swift`:

```swift
import Foundation

/// Read-only view over InsertionAuditLog's JSONL file (plus its .1 rotation
/// backup) for the pipeline viewer. Never writes. Parse failures skip the
/// line, IO failures yield an empty list — a forensics viewer must not grow
/// failure modes of its own.
@MainActor
final class InsertionReceiptStore: ObservableObject {
    @Published private(set) var receipts: [CaptureReceipt] = []

    private let fileURL: URL
    private let maxReceipts: Int
    private let maxTailBytes: Int
    private var lastStat: (size: UInt64, mtime: Date)?

    init(fileURL: URL = InsertionAuditLog.defaultFileURL,
         maxReceipts: Int = 50,
         maxTailBytes: Int = 262_144) {
        self.fileURL = fileURL
        self.maxReceipts = maxReceipts
        self.maxTailBytes = maxTailBytes
    }

    /// Newest receipt, for the palette's last-capture row.
    var latest: CaptureReceipt? { receipts.first }

    func refresh() {
        let stat = Self.stat(fileURL)
        if let stat, let last = lastStat, stat == last { return }
        lastStat = stat

        var lines = Self.tailLines(of: fileURL, maxBytes: maxTailBytes)
        if lines.count < maxReceipts {
            // Writer rotates at ~1 MB into exactly one backup:
            // insertions.jsonl -> insertions.1.jsonl (see InsertionAuditLog).
            let backup = fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
            lines = Self.tailLines(of: backup, maxBytes: maxTailBytes) + lines
        }
        let decoder = JSONDecoder()
        let parsed = lines.compactMap { line in
            try? decoder.decode(CaptureReceipt.self, from: Data(line.utf8))
        }
        // File order is chronological (append-only log), so the newest lines
        // are at the end; no ts sort needed.
        receipts = Array(parsed.suffix(maxReceipts).reversed())
    }

    private static func stat(_ url: URL) -> (size: UInt64, mtime: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (size, mtime)
    }

    private static func tailLines(of url: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        // A mid-file seek can split a UTF-8 sequence; String(decoding:) maps
        // the damage into the partial first line, which is dropped below.
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter InsertionReceiptStoreTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/InsertionReceiptStore.swift Tests/VoxFlowAppTests/InsertionReceiptStoreTests.swift
git commit -m "feat: InsertionReceiptStore — read-only tail reader over insertions.jsonl

@MainActor ObservableObject holding the newest 50 receipts. Reads only the
last 256 KB, spills into the .1.jsonl rotation backup when the main file is
short, no-ops when size+mtime are unchanged, and skips unparseable lines.
Never writes.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: CaptureReceiptRowModel (pure display mapping)

**Files:**
- Create: `Sources/VoxFlowApp/Services/CaptureReceiptRowModel.swift`
- Test: `Tests/VoxFlowAppTests/CaptureReceiptRowModelTests.swift`

**Interfaces:**
- Consumes: `CaptureReceipt`, `SourceLabel` (Task 1).
- Produces: `struct CaptureReceiptRowModel: Equatable` with `init(receipt: CaptureReceipt, now: Date = Date())` and properties `isReject: Bool`, `relativeTime: String`, `chips: [String]`, `targetLabel: String?`, `detail: String`, `snippet: String`, `rejectReason: String?`, `audioFileURL: URL?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VoxFlowAppTests/CaptureReceiptRowModelTests.swift`:

```swift
import XCTest
@testable import VoxFlowApp

/// Pure display mapping for a receipt row — extracted from the views so
/// formatting is unit-testable without SwiftUI. Custom relative-time buckets
/// (not RelativeDateTimeFormatter) keep tests deterministic across locales.
final class CaptureReceiptRowModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(
        event: String = "insert",
        secondsAgo: TimeInterval = 0,
        text: String? = "hello world",
        source: String? = "Inserted (light · rules — app)",
        target: String? = nil,
        confidence: Double? = nil,
        audioSeconds: Double? = nil,
        reason: String? = nil,
        audioFile: String? = nil
    ) -> CaptureReceipt {
        var fields = [
            "\"event\":\"\(event)\"",
            "\"ts\":\"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo)))\"",
        ]
        if let text { fields.append("\"text\":\"\(text)\"") }
        if let source { fields.append("\"source\":\"\(source)\"") }
        if let target { fields.append("\"target\":\"\(target)\"") }
        if let confidence { fields.append("\"confidence\":\(confidence)") }
        if let audioSeconds { fields.append("\"audio_seconds\":\(audioSeconds)") }
        if let reason { fields.append("\"reason\":\"\(reason)\"") }
        if let audioFile { fields.append("\"audio_file\":\"\(audioFile)\"") }
        let json = "{\(fields.joined(separator: ","))}"
        return try! JSONDecoder().decode(CaptureReceipt.self, from: Data(json.utf8))
    }

    func testRelativeTimeBuckets() {
        XCTAssertEqual(CaptureReceiptRowModel(receipt: receipt(secondsAgo: 30), now: now).relativeTime, "now")
        XCTAssertEqual(CaptureReceiptRowModel(receipt: receipt(secondsAgo: 5 * 60), now: now).relativeTime, "5m ago")
        XCTAssertEqual(CaptureReceiptRowModel(receipt: receipt(secondsAgo: 2 * 3600), now: now).relativeTime, "2h ago")
        XCTAssertEqual(CaptureReceiptRowModel(receipt: receipt(secondsAgo: 3 * 86_400), now: now).relativeTime, "3d ago")
    }

    func testChipsComeFromSourceLabelTokens() {
        let row = CaptureReceiptRowModel(receipt: receipt(), now: now)
        XCTAssertEqual(row.chips, ["light", "rules"])
        XCTAssertFalse(row.isReject)
    }

    func testTargetPrefersReceiptTargetOverAppLabel() {
        let row = CaptureReceiptRowModel(receipt: receipt(target: "Notes"), now: now)
        XCTAssertEqual(row.targetLabel, "Notes")
        let fallback = CaptureReceiptRowModel(receipt: receipt(), now: now)
        XCTAssertEqual(fallback.targetLabel, "app")
    }

    func testDetailJoinsDurationAndConfidence() {
        let row = CaptureReceiptRowModel(
            receipt: receipt(confidence: 0.914, audioSeconds: 3.42), now: now)
        XCTAssertEqual(row.detail, "3.4s · 91%")
        let empty = CaptureReceiptRowModel(receipt: receipt(), now: now)
        XCTAssertEqual(empty.detail, "")
    }

    func testSnippetTruncatesAt60CharsWithEllipsis() {
        let long = String(repeating: "a", count: 80)
        let row = CaptureReceiptRowModel(receipt: receipt(text: long), now: now)
        XCTAssertEqual(row.snippet, String(repeating: "a", count: 60) + "…")
        let short = CaptureReceiptRowModel(receipt: receipt(text: "short"), now: now)
        XCTAssertEqual(short.snippet, "short")
    }

    func testRejectMapping() {
        let row = CaptureReceiptRowModel(
            receipt: receipt(event: "reject", source: "quick_dictation",
                             reason: "empty", audioFile: "/tmp/r.wav"),
            now: now)
        XCTAssertTrue(row.isReject)
        XCTAssertEqual(row.rejectReason, "empty")
        XCTAssertEqual(row.audioFileURL, URL(fileURLWithPath: "/tmp/r.wav"))
        XCTAssertEqual(row.chips, ["quick_dictation"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CaptureReceiptRowModelTests 2>&1 | tail -5`
Expected: compile FAILURE with `cannot find 'CaptureReceiptRowModel' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VoxFlowApp/Services/CaptureReceiptRowModel.swift`:

```swift
import Foundation

/// Pure display mapping for one receipt row, shared by the palette
/// last-capture row and the Dashboard Recent Captures section. Extracted from
/// the views so formatting is unit-testable without SwiftUI.
struct CaptureReceiptRowModel: Equatable {
    let isReject: Bool
    let relativeTime: String
    let chips: [String]
    let targetLabel: String?
    let detail: String
    let snippet: String
    let rejectReason: String?
    let audioFileURL: URL?

    init(receipt: CaptureReceipt, now: Date = Date()) {
        isReject = receipt.event == .reject
        relativeTime = Self.relative(receipt.ts, now: now)
        let label = receipt.sourceLabel
        chips = label.tokens
        targetLabel = receipt.target ?? label.appLabel
        var parts: [String] = []
        if let seconds = receipt.audioSeconds {
            parts.append(String(format: "%.1fs", seconds))
        }
        if let confidence = receipt.confidence {
            parts.append("\(Int((confidence * 100).rounded()))%")
        }
        detail = parts.joined(separator: " · ")
        let text = receipt.text ?? ""
        snippet = text.count > 60 ? String(text.prefix(60)) + "…" : text
        rejectReason = receipt.reason
        audioFileURL = receipt.audioFile.map { URL(fileURLWithPath: $0) }
    }

    // Fixed buckets instead of RelativeDateTimeFormatter: deterministic under
    // test and immune to locale variance.
    private static func relative(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CaptureReceiptRowModelTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Services/CaptureReceiptRowModel.swift Tests/VoxFlowAppTests/CaptureReceiptRowModelTests.swift
git commit -m "feat: CaptureReceiptRowModel — pure display mapping for receipt rows

Relative-time buckets, source-label chips, target fallback, duration/confidence
detail string, 60-char snippet, reject reason + retained-audio URL. Shared by
the palette last-capture row and the Dashboard section (next tasks).

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: AppCoordinator wiring + palette last-capture row

**Files:**
- Modify: `Sources/VoxFlowApp/AppCoordinator.swift` (~line 98: add lazy property; ~line 2001: pass store into palette)
- Modify: `Sources/VoxFlowApp/Views/CommandPaletteView.swift` (property, row view, body slot, refresh triggers)

**Interfaces:**
- Consumes: `InsertionReceiptStore` (Task 2), `CaptureReceiptRowModel` (Task 3), existing `AppState.captureCount: Int` and `AppState.statusLine: String` (both `@Published`, both Equatable — `InsertResult` is NOT Equatable, do not use `lastInsertResult` in `.onChange`).
- Produces: `AppCoordinator.receiptStore` (`private(set) lazy var`), `CommandPaletteView.receiptStore` (`@ObservedObject`) — Task 5 reuses the same store via `coordinator.receiptStore`.

No new unit tests in this task: the row's logic lives in `CaptureReceiptRowModel` (tested in Task 3); this task is mechanical SwiftUI wiring, verified by build + full suite + the repo's existing view-construction smoke coverage.

- [ ] **Step 1: Add the store to AppCoordinator**

In `Sources/VoxFlowApp/AppCoordinator.swift`, directly below the existing line (~98):

```swift
    private(set) lazy var insertionAudit = InsertionAuditLog()
```

add:

```swift
    /// Read-only receipts view for the pipeline viewer (palette + dashboard).
    private(set) lazy var receiptStore = InsertionReceiptStore()
```

- [ ] **Step 2: Pass the store into the palette**

In `setupMenuBarPanel()` (~line 2001), add the argument after `state: state,`:

```swift
        let panelContent = CommandPaletteView(
            coordinator: self,
            state: state,
            receiptStore: receiptStore,
            onOpenDashboardWindow: {
```

- [ ] **Step 3: Add the property and row to CommandPaletteView**

In `Sources/VoxFlowApp/Views/CommandPaletteView.swift`, after `@ObservedObject var state: AppState` add:

```swift
    @ObservedObject var receiptStore: InsertionReceiptStore
```

(If the build later reports another construction site, e.g. a `#Preview`, pass `coordinator.receiptStore` or a fresh `InsertionReceiptStore(fileURL:)` there too.)

In `body`, insert the row between the `state.errorMessage` block and `footerBar`:

```swift
            if let error = state.errorMessage {
                // ... existing block unchanged ...
            }

            lastCaptureRow

            footerBar
```

Extend the existing `.onAppear` and add two `.onChange` triggers after it:

```swift
        .onAppear {
            updateRecordingBadgeAnimation()
            receiptStore.refresh()
        }
        .onChange(of: state.captureCount) { _, _ in receiptStore.refresh() }
        .onChange(of: state.statusLine) { _, _ in receiptStore.refresh() }
```

(The existing `.onChange(of: state.sessionState)` stays as is.)

Add the row view alongside the other private views (e.g. below `footerBar`):

```swift
    /// Persistent last-capture provenance row — the pipeline stage card
    /// vanishes the instant an insert lands; this stays until the next
    /// capture replaces it. Rejects render tinted with their reason.
    @ViewBuilder private var lastCaptureRow: some View {
        if let receipt = receiptStore.latest {
            let row = CaptureReceiptRowModel(receipt: receipt)
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: row.isReject ? "xmark.circle" : "checkmark.circle")
                    .font(VF.captionFont)
                    .foregroundStyle(row.isReject ? VF.colorWarning : VF.colorSuccess)
                Text(row.relativeTime)
                    .font(VF.microFont)
                    .foregroundStyle(.secondary)
                ForEach(row.chips, id: \.self) { chip in
                    Text(chip)
                        .font(VF.microFont)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(VF.cardBackground, in: Capsule())
                }
                if let target = row.targetLabel {
                    Text(target)
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                }
                if let reason = row.rejectReason {
                    Text(reason)
                        .font(VF.microFont)
                        .foregroundStyle(VF.colorWarning)
                }
                Text(row.snippet)
                    .font(VF.microFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.isReject
                ? "Last capture rejected: \(row.rejectReason ?? "unknown")"
                : "Last capture inserted via \(row.chips.joined(separator: ", "))")
        }
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 671 tests, with 0 failures` (643 baseline + 28 from Tasks 1-3; exact count may differ by a few — the requirement is 0 failures).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/AppCoordinator.swift Sources/VoxFlowApp/Views/CommandPaletteView.swift
git commit -m "feat: persistent last-capture provenance row in the command palette

AppCoordinator owns an InsertionReceiptStore; the palette renders the newest
receipt (outcome, chips, target, duration/confidence, snippet, reject reason)
between the error block and the footer, refreshed on appear and on
captureCount/statusLine changes. No capture-path changes.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Dashboard Recent Captures section + docs

**Files:**
- Modify: `Sources/VoxFlowApp/Views/DashboardWindowView.swift` (property, section, rows, reveal button)
- Modify: `Sources/VoxFlowApp/VoxFlowLocalApp.swift:81` (pass store)
- Modify: `CHANGELOG.md` (Unreleased entry)
- Modify: `CLAUDE.md` (Services list line)

**Interfaces:**
- Consumes: `AppCoordinator.receiptStore` (Task 4), `CaptureReceiptRowModel` (Task 3).
- Produces: user-facing Dashboard section; nothing downstream.

- [ ] **Step 1: Pass the store into the Dashboard**

In `Sources/VoxFlowApp/VoxFlowLocalApp.swift` (~line 81) change:

```swift
            DashboardWindowView(coordinator: coordinator, state: coordinator.state)
```

to:

```swift
            DashboardWindowView(
                coordinator: coordinator,
                state: coordinator.state,
                receiptStore: coordinator.receiptStore)
```

- [ ] **Step 2: Add the section to DashboardWindowView**

In `Sources/VoxFlowApp/Views/DashboardWindowView.swift`:

Add `import AppKit` below `import SwiftUI` (for `NSWorkspace`).

Add the property after `@ObservedObject var state: AppState`:

```swift
    @ObservedObject var receiptStore: InsertionReceiptStore
```

In `body`, insert the section after `modeUsageSection`:

```swift
                backendSection
                modeUsageSection
                recentCapturesSection
                benchmarkRecommendationSection
```

Add the section and row views alongside the other private sections:

```swift
    /// Pipeline provenance history: the newest receipts from insertions.jsonl,
    /// rejects included. Read-only — the file is written by InsertionAuditLog.
    private var recentCapturesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Captures")
                .font(VF.headingFont)
                .foregroundStyle(.secondary)

            if receiptStore.receipts.isEmpty {
                Text("No captures recorded yet")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(receiptStore.receipts.enumerated()), id: \.offset) { _, receipt in
                        recentCaptureRow(receipt)
                    }
                }
            }
        }
        .onAppear { receiptStore.refresh() }
        .onChange(of: state.captureCount) { _, _ in receiptStore.refresh() }
        .onChange(of: state.statusLine) { _, _ in receiptStore.refresh() }
    }

    private func recentCaptureRow(_ receipt: CaptureReceipt) -> some View {
        let row = CaptureReceiptRowModel(receipt: receipt)
        return HStack(spacing: VF.spacingSmall) {
            Image(systemName: row.isReject ? "xmark.circle" : "checkmark.circle")
                .font(VF.captionFont)
                .foregroundStyle(row.isReject ? VF.colorWarning : VF.colorSuccess)
            Text(row.relativeTime)
                .font(VF.monoCaptionFont)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            ForEach(row.chips, id: \.self) { chip in
                Text(chip)
                    .font(VF.microFont)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(VF.cardBackground, in: Capsule())
            }
            if let target = row.targetLabel {
                Text(target)
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }
            if let reason = row.rejectReason {
                Text(reason)
                    .font(VF.captionFont)
                    .foregroundStyle(VF.colorWarning)
            }
            Text(row.snippet)
                .font(VF.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let url = row.audioFileURL {
                // Rejects that retained their audio (RejectedAudioStore ring)
                // get a one-click path to the WAV for forensic triage.
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "waveform.circle")
                }
                .buttonStyle(.plain)
                .help("Reveal retained audio in Finder")
            }
        }
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures, same count as Task 4.

- [ ] **Step 4: Update CHANGELOG.md and CLAUDE.md**

In `CHANGELOG.md`, under `## [Unreleased]` (add an `### Added` heading if the section does not already have one):

```markdown
### Added
- Pipeline viewer: persistent last-capture provenance row in the command
  palette and a Recent Captures section in the Dashboard (mode, served-by,
  target, duration, confidence, reject reason, reveal-retained-audio), read
  from `insertions.jsonl`. Read-only; no capture-path changes.
```

In `CLAUDE.md`, in the `Sources/VoxFlowApp/Services/` architecture list, add after the `SessionMemoryStore.swift` line:

```
    InsertionReceiptStore.swift         Read-only insertions.jsonl tail reader — palette last-capture row + Dashboard Recent Captures (CaptureReceipt/RowModel)
```

- [ ] **Step 5: Commit**

```bash
git add Sources/VoxFlowApp/Views/DashboardWindowView.swift Sources/VoxFlowApp/VoxFlowLocalApp.swift CHANGELOG.md CLAUDE.md
git commit -m "feat: Recent Captures pipeline-provenance section in the Dashboard

Newest 50 receipts with outcome, chips, target, duration/confidence, snippet,
reject reason, and a reveal-in-Finder button for rejects that retained audio.
Changelog + CLAUDE.md services list updated.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: End-to-end verification against real receipts

**Files:** none created; verification only.

**Interfaces:** consumes everything above.

- [ ] **Step 1: Full suite**

Run: `swift test 2>&1 | tail -3` and `./.venv/bin/python -m pytest backend/tests -q 2>&1 | tail -2`
Expected: 0 Swift failures; `519 passed, 26 skipped` (Python untouched — this confirms it).

- [ ] **Step 2: Run the app against the real log**

Run: `swift run VoxFlowLocal` (backend need not be warm; the viewer reads a file).

Verify by hand:
- Palette shows a last-capture row derived from the real `~/Library/Logs/VoxFlow/insertions.jsonl` (the user's newest receipt, e.g. chips `light` + `rules`).
- Dashboard (⌘2 from the palette footer) shows the Recent Captures section with ~50 rows, rejects tinted orange with reasons, and a waveform button on any reject that retained audio (three exist as of 2026-07-12).
- Dictate once; both surfaces update after the insert without reopening.

- [ ] **Step 3: Report**

Report actual observed behavior (with any deviations) back to the user before merging. Do not claim success without having watched the surfaces update.
