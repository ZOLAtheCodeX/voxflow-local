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
