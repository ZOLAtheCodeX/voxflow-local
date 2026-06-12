import XCTest
@testable import VoxFlowApp

/// Ghost-hello forensics: every insertion and every gate rejection gets a
/// local JSONL receipt, because macOS does not persist info-level os_log —
/// repeated user reports of phantom text were unattributable post-hoc.
@MainActor
final class InsertionAuditLogTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() async throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-audit-\(UUID().uuidString)")
            .appendingPathComponent("insertions.jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    func testRecordsInsertionAsJSONLine() throws {
        let log = InsertionAuditLog(fileURL: tempURL)
        log.recordInsertion(text: "hello world", targetApp: "Notes", source: "quick_dictation", confidence: 0.91)
        let lines = try String(contentsOf: tempURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let obj = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "insert")
        XCTAssertEqual(obj?["text"] as? String, "hello world")
        XCTAssertEqual(obj?["target"] as? String, "Notes")
        XCTAssertEqual(obj?["source"] as? String, "quick_dictation")
        XCTAssertNotNil(obj?["ts"])
    }

    func testRecordsGateRejection() throws {
        let log = InsertionAuditLog(fileURL: tempURL)
        log.recordRejection(text: "hello", reason: "hallucination_filter", confidence: 0.05, durationSeconds: 3.2, source: "quick_dictation")
        let line = try String(contentsOf: tempURL, encoding: .utf8)
        let obj = try JSONSerialization.jsonObject(with: Data(line.split(separator: "\n")[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["event"] as? String, "reject")
        XCTAssertEqual(obj?["reason"] as? String, "hallucination_filter")
    }

    func testRotatesWhenOversized() throws {
        let log = InsertionAuditLog(fileURL: tempURL, maxBytes: 400)
        for i in 0..<20 {
            log.recordInsertion(text: "padding padding padding \(i)", targetApp: "X", source: "test", confidence: 1.0)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 1200, "log must rotate, not grow unbounded")
        let rotated = tempURL.deletingPathExtension().appendingPathExtension("1.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
    }
}
