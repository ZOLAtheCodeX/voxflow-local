import Foundation
import os

/// Retains the PCM of rejected captures as WAV files so a decode-to-empty
/// failure is attributable after the fact (listen to it, re-decode it,
/// `/v1/audio/diagnose` it) and the dictation itself is recoverable — before
/// session 29 the audio was in memory at the moment of rejection and simply
/// discarded, which made 4–12 s "empty" losses both unexplainable and
/// unrecoverable.
///
/// Privacy posture matches insertions.jsonl: local-only, under
/// ~/Library/Logs/VoxFlow/, content the user dictated on their own machine.
/// Bounded ring (newest `maxClips` files); `VOXFLOW_KEEP_REJECTED_AUDIO=0`
/// disables retention entirely.
struct RejectedAudioStore {
    let directory: URL
    let maxClips: Int
    let enabled: Bool

    private static let log = Logger(subsystem: "local.voxflow.app", category: "RejectedAudioStore")

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("VoxFlow", isDirectory: true)
            .appendingPathComponent("rejected_audio", isDirectory: true)
    }

    nonisolated static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["VOXFLOW_KEEP_REJECTED_AUDIO"] != "0"
    }

    init(
        directory: URL = RejectedAudioStore.defaultDirectory,
        maxClips: Int = 8,
        enabled: Bool = RejectedAudioStore.isEnabled()
    ) {
        self.directory = directory
        self.maxClips = maxClips
        self.enabled = enabled
    }

    /// Writes the capture as a WAV (PCM16 mono at `sampleRate`) named by
    /// timestamp + reason, prunes the ring to `maxClips`, and returns the
    /// file URL for the audit receipt. Returns nil when disabled, when the
    /// PCM is empty, or on any I/O failure — retention must never break the
    /// rejection path it instruments.
    @discardableResult
    func store(pcm: Data, sampleRate: Double, reason: String, at date: Date = Date()) -> URL? {
        guard enabled, !pcm.isEmpty else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Self.filenameStamp(for: date)
            let url = directory.appendingPathComponent(
                "reject-\(stamp)-\(reason)-\(UUID().uuidString.prefix(8)).wav")
            try Self.wavData(pcm: pcm, sampleRate: sampleRate).write(to: url, options: .atomic)
            prune()
            return url
        } catch {
            Self.log.error("Failed to retain rejected capture: \(error.localizedDescription)")
            return nil
        }
    }

    /// Sortable, filesystem-safe UTC stamp with ms precision so a plain
    /// directory listing reads oldest→newest and prune-by-name is correct.
    private static func filenameStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return formatter.string(from: date)
    }

    /// Keep the newest `maxClips` files (by the sortable filename stamp).
    private func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "wav" }) else { return }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in sorted.dropFirst(maxClips) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    /// Canonical 44-byte RIFF/WAVE header + PCM16 mono payload.
    static func wavData(pcm: Data, sampleRate: Double) -> Data {
        let rate = UInt32(sampleRate)
        let byteRate = rate * 2 // mono, 16-bit
        var wav = Data(capacity: 44 + pcm.count)
        wav.append(contentsOf: Array("RIFF".utf8))
        wav.appendLE(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        wav.appendLE(UInt32(16))          // fmt chunk size
        wav.appendLE(UInt16(1))           // PCM
        wav.appendLE(UInt16(1))           // mono
        wav.appendLE(rate)
        wav.appendLE(byteRate)
        wav.appendLE(UInt16(2))           // block align
        wav.appendLE(UInt16(16))          // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        wav.appendLE(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
