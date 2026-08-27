import CryptoKit
import Foundation
import os

/// What a receipt keeps of the dictated text itself.
///
/// The log exists to attribute a phantom insertion after the fact, and the text
/// is what makes one insertion distinguishable from the next. It is also, for
/// anyone dictating privileged or client-identifying material, a plain-text copy
/// of that material on disk in a predictable place, still there long after the
/// dictation was inserted and the app was quit.
///
/// `.digest` is the middle setting and keeps attribution without keeping
/// content. A truncated SHA-256 still tells two insertions apart, and still
/// matches a phrase a user reports if you hash that phrase, but reading the log
/// reveals nothing. `.none` keeps only the length.
///
/// The default stays `.full`. This log was built for a specific bug class, and
/// weakening it by default would quietly take that away from every user to serve
/// a case most of them do not have.
enum AuditTextRetention: String {
    case full
    case digest
    case none

    static let defaultsKey = "VoxFlow.auditTextRetention"

    /// Unset, empty, or unrecognized all resolve to `.full`. A typo in the
    /// defaults value must not silently reduce forensics.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> AuditTextRetention {
        guard let raw = defaults.string(forKey: defaultsKey),
              let parsed = AuditTextRetention(rawValue: raw) else { return .full }
        return parsed
    }
}

/// Local forensics for the ghost-text bug class. Every text insertion and
/// every TranscriptGate rejection appends one JSON line to
/// ~/Library/Logs/VoxFlow/insertions.jsonl — because macOS does not persist
/// info-level os_log, repeated phantom-"hello" reports were unattributable
/// after the fact. The file is local-only and rotates at ~1 MB (one .1 backup).
///
/// By default a receipt carries the dictated text, which is what makes a
/// specific phantom insertion identifiable. `AuditTextRetention` narrows that
/// to a digest or to a length alone for anyone who should not leave dictated
/// content on disk. See that type for why the default is not the narrow one.
@MainActor
final class InsertionAuditLog {
    private let fileURL: URL
    private let maxBytes: Int
    private let retention: AuditTextRetention
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

    init(
        fileURL: URL = InsertionAuditLog.defaultFileURL,
        maxBytes: Int = 1_000_000,
        retention: AuditTextRetention = .fromDefaults()
    ) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.retention = retention
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// The text-bearing fields for one receipt, under the active retention.
    /// `chars` is emitted at every level: it costs nothing, reveals nothing, and
    /// is what the tail-loss check compares against `audio_seconds`.
    private func textFields(_ text: String) -> [String: Any] {
        switch retention {
        case .full:
            return ["text": text, "chars": text.count]
        case .digest:
            return ["text_sha256": Self.shortDigest(text), "chars": text.count]
        case .none:
            return ["chars": text.count]
        }
    }

    /// First 6 bytes of SHA-256, hex. Enough to tell insertions apart and to
    /// match a phrase a user reports by hashing it; not enough to be a
    /// meaningful target for anyone reading the log.
    nonisolated static func shortDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
    }

    func recordInsertion(
        text: String,
        targetApp: String?,
        source: String,
        confidence: Double?,
        audioSeconds: Double? = nil,
        rmsEnergy: Double? = nil,
        peakAmplitude: Double? = nil,
        tailGapSeconds: Double? = nil,
        sttMs: Int? = nil,
        cleanupMs: Int? = nil,
        insertMs: Int? = nil,
        totalMs: Int? = nil,
        insertMethod: String? = nil
    ) {
        var entry: [String: Any] = [
            "event": "insert",
            "ts": iso.string(from: Date()),
            "source": source,
        ]
        entry.merge(textFields(text)) { _, new in new }
        if let targetApp { entry["target"] = targetApp }
        if let confidence { entry["confidence"] = confidence }
        // Tail-loss forensics: with duration/rms/peak on SUCCESSFUL inserts,
        // a transcript that only covers the head of a long capture (decoder
        // early-stop) is detectable post-hoc — chars vs audio_seconds. Absent
        // for insert paths with no captured audio (snippets, re-inserts).
        if let audioSeconds { entry["audio_seconds"] = audioSeconds }
        if let rmsEnergy { entry["rms"] = rmsEnergy }
        if let peakAmplitude { entry["peak_amplitude"] = peakAmplitude }
        // Seconds of speech-bearing audio after the last transcribed segment
        // (partial decode / tail loss, session 29). Absent = full coverage.
        if let tailGapSeconds { entry["tail_gap_seconds"] = tailGapSeconds }
        // Latency forensics (session 32): per-stage ms + total from hotkey
        // release, and the insert method (AX-direct vs paste) for per-app tuning.
        if let sttMs { entry["stt_ms"] = sttMs }
        if let cleanupMs { entry["cleanup_ms"] = cleanupMs }
        if let insertMs { entry["insert_ms"] = insertMs }
        if let totalMs { entry["total_ms"] = totalMs }
        if let insertMethod { entry["insert_method"] = insertMethod }
        append(entry)
    }

    func recordRejection(
        text: String,
        reason: String,
        confidence: Double,
        durationSeconds: Double,
        source: String,
        rmsEnergy: Double? = nil,
        leadingSilenceSeconds: Double? = nil,
        firstBufferLatencyMs: Int? = nil,
        secondsSinceLastCapture: Double? = nil,
        appliedGainDB: Double? = nil,
        meanNoSpeechProb: Double? = nil,
        segmentCount: Int? = nil,
        peakAmplitude: Double? = nil,
        audioFile: String? = nil,
        expectedAudioSeconds: Double? = nil
    ) {
        var entry: [String: Any] = [
            "event": "reject",
            "ts": iso.string(from: Date()),
            "reason": reason,
            "confidence": confidence,
            "audio_seconds": durationSeconds,
            "source": source,
        ]
        entry.merge(textFields(text)) { _, new in new }
        // RMS distinguishes "you were silent" (near 0) from "your mic is too
        // quiet to decode" (above the silence floor but below speech level) —
        // the difference between the two empty-capture failure modes.
        if let rmsEnergy { entry["rms"] = rmsEnergy }
        // Cold-start instrumentation for the empty-capture investigation:
        // elevated leading silence / first-buffer latency on empties points at
        // front-clip (engine not yet armed), not low gain.
        if let leadingSilenceSeconds { entry["leading_silence_seconds"] = leadingSilenceSeconds }
        if let firstBufferLatencyMs { entry["first_buffer_latency_ms"] = firstBufferLatencyMs }
        // applied_gain_db = how much the decoder-side normalizer boosted this
        // capture; seconds_since_last_capture tests the "healthy-level miss after
        // idle" (cold pipeline) hypothesis the gain fix can't explain.
        if let secondsSinceLastCapture { entry["seconds_since_last_capture"] = secondsSinceLastCapture }
        if let appliedGainDB { entry["applied_gain_db"] = appliedGainDB }
        // Decode internals for the residual healthy-RMS empties: was it the
        // model's no-speech VAD (high mean_no_speech_prob), no decode output at
        // all (segment_count 0), or a transient-in-silence (high peak, low rms)?
        if let meanNoSpeechProb { entry["mean_no_speech_prob"] = meanNoSpeechProb }
        if let segmentCount { entry["segment_count"] = segmentCount }
        if let peakAmplitude { entry["peak_amplitude"] = peakAmplitude }
        // Path of the retained WAV (RejectedAudioStore), so triage lands on
        // the actual audio instead of inferring from rms/peak (session 29).
        if let audioFile { entry["audio_file"] = audioFile }
        // Wall-clock span the PCM should cover — audio_seconds well below it
        // means the device dropped buffers mid-capture (coverage shortfall).
        if let expectedAudioSeconds { entry["expected_audio_seconds"] = expectedAudioSeconds }
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
