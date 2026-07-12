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
