import Foundation

/// Coverage-based confidence for WhisperKit transcription results.
///
/// Parity with the backend's `WhisperEngine._estimate_confidence`
/// (backend/app/engines/whisper.py): how much of the audio was actually
/// spoken drives the estimate, and a lone word from a long clip is crushed.
/// Adds a WhisperKit-only signal the HF pipeline does not expose: per-segment
/// `noSpeechProb`. The old estimate (`exp(avgLogprob)` of the first segment)
/// scored multi-word noise hallucinations 0.3-0.6 — past every gate.
enum TranscriptionConfidence {
    struct SegmentSignal {
        let startSeconds: Double
        let endSeconds: Double
        let noSpeechProb: Double
    }

    static func estimate(segments: [SegmentSignal], text: String, audioDurationSeconds: Double) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let wordCount = text.split(whereSeparator: \.isWhitespace).count

        let spoken = segments.reduce(0.0) { $0 + max(0.0, $1.endSeconds - $1.startSeconds) }

        let coverage: Double
        if spoken > 0, audioDurationSeconds > 0 {
            coverage = min(1.0, spoken / audioDurationSeconds)
        } else {
            // No usable timestamps: fall back to words-per-second plausibility
            // (~2.5 words/s for natural dictation), mirroring the backend.
            let expectedWords = audioDurationSeconds * 2.5
            coverage = min(1.0, Double(wordCount) / max(expectedWords, 1.0))
        }

        var confidence = min(0.95, max(0.05, coverage))

        // Lone-word crush (the ghost signature: a word invented from long
        // noise) — EXCEPT when the model itself strongly attests speech
        // (near-zero mean noSpeechProb) over substantial spoken time. A
        // clear, loud "Approved." in a 3 s capture is coverage-poor but
        // speech-certain; crushing it on geometry alone deterministically
        // rejected legitimate quick dictations (session 29 review). Blip
        // segments (< 0.5 s) never qualify: blips are the classic
        // noise-invention shape regardless of noSpeechProb.
        let meanNoSpeech = segments.isEmpty
            ? nil : segments.reduce(0.0) { $0 + $1.noSpeechProb } / Double(segments.count)
        let attestedSpeech = (meanNoSpeech ?? 1.0) < 0.15 && spoken >= 0.5
        if wordCount <= 2, audioDurationSeconds > 2.0, coverage < 0.3, !attestedSpeech {
            confidence = min(confidence, 0.1)
        }

        if let meanNoSpeech, meanNoSpeech > 0.5 {
            confidence = min(confidence, 0.1)
        }

        return (confidence * 1000).rounded() / 1000
    }
}
