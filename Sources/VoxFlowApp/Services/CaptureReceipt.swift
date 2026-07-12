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
