import Foundation
import os

/// Local forensics for the ghost-text bug class. Every text insertion and
/// every TranscriptGate rejection appends one JSON line to
/// ~/Library/Logs/VoxFlow/insertions.jsonl — because macOS does not persist
/// info-level os_log, repeated phantom-"hello" reports were unattributable
/// after the fact. The file is local-only, plain text the user already
/// dictated on their own machine, and rotates at ~1 MB (one .1 backup).
@MainActor
final class InsertionAuditLog {
    private let fileURL: URL
    private let maxBytes: Int
    private let log = Logger(subsystem: "local.voxflow.app", category: "InsertionAuditLog")
    private let iso = ISO8601DateFormatter()

    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VoxFlow", isDirectory: true)
            .appendingPathComponent("insertions.jsonl")
    }

    init(fileURL: URL = InsertionAuditLog.defaultFileURL, maxBytes: Int = 1_000_000) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func recordInsertion(text: String, targetApp: String?, source: String, confidence: Double?) {
        var entry: [String: Any] = [
            "event": "insert",
            "ts": iso.string(from: Date()),
            "text": text,
            "chars": text.count,
            "source": source,
        ]
        if let targetApp { entry["target"] = targetApp }
        if let confidence { entry["confidence"] = confidence }
        append(entry)
    }

    func recordRejection(text: String, reason: String, confidence: Double, durationSeconds: Double, source: String, rmsEnergy: Double? = nil) {
        var entry: [String: Any] = [
            "event": "reject",
            "ts": iso.string(from: Date()),
            "text": text,
            "reason": reason,
            "confidence": confidence,
            "audio_seconds": durationSeconds,
            "source": source,
        ]
        // RMS distinguishes "you were silent" (near 0) from "your mic is too
        // quiet to decode" (above the silence floor but below speech level) —
        // the difference between the two empty-capture failure modes.
        if let rmsEnergy { entry["rms"] = rmsEnergy }
        append(entry)
    }

    /// Replace any non-finite Double (NaN/±Inf) with a marker string. JSON has
    /// no representation for them, so JSONSerialization would otherwise throw and
    /// drop the WHOLE record — defeating the point of a forensics log.
    private func sanitize(_ entry: [String: Any]) -> [String: Any] {
        var clean = entry
        for (key, value) in entry where (value as? Double).map({ !$0.isFinite }) == true {
            clean[key] = "non-finite"
        }
        return clean
    }

    private func append(_ entry: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: sanitize(entry)) else {
            log.error("InsertionAuditLog: dropped a non-serializable audit entry")
            return
        }
        rotateIfNeeded()
        if let handle = FileHandle(forWritingAtPath: fileURL.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data("\n".utf8))
        } else {
            try? (String(data: data, encoding: .utf8)! + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              size >= maxBytes else { return }
        let backup = fileURL.deletingPathExtension().appendingPathExtension("1.jsonl")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
    }
}
