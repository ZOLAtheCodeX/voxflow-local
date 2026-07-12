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
