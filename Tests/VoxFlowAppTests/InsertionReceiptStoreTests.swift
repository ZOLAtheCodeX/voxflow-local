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
