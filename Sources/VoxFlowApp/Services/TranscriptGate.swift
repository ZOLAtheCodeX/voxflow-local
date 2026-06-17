import Foundation

/// The single gate every transcript must pass before it can reach insertion,
/// the cockpit transcript, or the command lane.
///
/// Layers, in order: empty/placeholder rejection, the hallucination phrase
/// filter, then the low-confidence rules. The third confidence clause is the
/// "ghost signature": a 1-3 word result from > 4 s of audio whose
/// coverage-based confidence collapsed to <= 0.1 (see
/// `TranscriptionConfidence`) is Whisper inventing speech from noise —
/// regardless of what the words are. Full sentences are never rejected on
/// confidence alone.
enum TranscriptGate {
    /// Minimum capture length worth transcribing — shared by the quick
    /// dictation path and the cockpit chunk loop.
    static let minAudioSeconds = 0.3

    /// Why a transcript (or capture) was rejected. Typed so consumers like
    /// `CaptureFeedback` and the audit log can't silently fall out of sync with
    /// a renamed reason. The raw value is the stable string used in the JSONL
    /// audit receipts and logs. `.silence` is produced upstream (dead-air
    /// captures rejected before this gate runs), not by `evaluate`.
    enum Rejection: String, Equatable {
        case empty
        case placeholder
        case hallucinationFilter = "hallucination_filter"
        case lowConfidence = "low_confidence"
        case silence
    }

    enum Verdict: Equatable {
        case accepted
        case rejected(reason: Rejection)
    }

    static func evaluate(text: String, confidence: Double, audioDurationSeconds: Double) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .rejected(reason: .empty) }
        if trimmed.hasPrefix("[transcription") { return .rejected(reason: .placeholder) }

        let shortAudio = audioDurationSeconds < 3.0
        if HallucinationFilter.isLikelyHallucination(trimmed, shortAudio: shortAudio) {
            return .rejected(reason: .hallucinationFilter)
        }

        let wordCount = trimmed.split(whereSeparator: \.isWhitespace).count
        let isSuspect = (wordCount == 1 && confidence < 0.15)
            || (shortAudio && wordCount <= 2 && confidence < 0.08)
            || (wordCount <= 3 && audioDurationSeconds > 4.0 && confidence <= 0.1)
        if isSuspect { return .rejected(reason: .lowConfidence) }

        return .accepted
    }
}
