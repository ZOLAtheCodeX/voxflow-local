import Foundation

/// User-facing feedback for a capture that produced no usable transcript.
///
/// Splits the ambiguous "nothing came back" case into "you were silent" vs
/// "your microphone input is too weak". An empty or low-confidence transcript
/// from several seconds of above-silence audio is almost always an input-device
/// problem the user can fix (wrong input selected, low gain, muffled mic),
/// not a sign they said nothing. Surfacing that distinction turns a dead-end
/// "No speech detected" into an actionable hint.
enum CaptureFeedback {
    /// Map a `TranscriptGate.Rejection` plus the captured audio energy to the
    /// status line shown to the user.
    ///
    /// `.silence`, `.empty`, and `.lowConfidence` can all stem from a weak/dead
    /// input, so a sub-speech RMS earns the actionable mic hint (`.silence` —
    /// near-zero RMS — always does, since it's below `CapturedAudio.speechFloor`
    /// by definition). `.placeholder` and `.hallucinationFilter` are content the
    /// model invented, where input level is irrelevant — generic message only.
    static func rejectionStatus(reason: TranscriptGate.Rejection, rmsEnergy: Double) -> String {
        switch reason {
        case .silence, .empty, .lowConfidence:
            return rmsEnergy < CapturedAudio.speechFloor
                ? "Very low mic level — check your input in System Settings → Sound"
                : "No speech detected — try again"
        case .placeholder, .hallucinationFilter:
            return "No speech detected — try again"
        }
    }

    /// Coverage-shortfall warning (session 29): the PCM covers materially
    /// less time than the wall-clock recording span, i.e. audio was LOST
    /// mid-capture (dropped IO buffers under memory pressure, stalled
    /// device). Returns a status-line suffix, or nil when coverage is
    /// healthy, the span is too short to judge (start/stop slop dominates
    /// under ~3 s), or the expected span was not measured.
    static func coverageWarning(durationSeconds: Double, expectedSeconds: Double?) -> String? {
        guard let expectedSeconds, expectedSeconds >= 3.0 else { return nil }
        let coverage = durationSeconds / expectedSeconds
        guard coverage < 0.85 else { return nil }
        return String(
            format: " — audio device dropped ~%.0f s of the recording",
            max(0, expectedSeconds - durationSeconds))
    }

    /// Sharpen the empty-capture message with a Silero speech-presence
    /// diagnosis (R6, `/v1/audio/diagnose`): "speech but too quiet" vs "only
    /// background noise" vs "speech but not recognized" — the RMS heuristic
    /// alone cannot tell noise from weak speech. Falls back to
    /// ``rejectionStatus(reason:rmsEnergy:)`` whenever the diagnosis is
    /// missing or failed open (`vadAvailable == false`), and for
    /// invented-content rejections (placeholder/hallucination) where speech
    /// presence is irrelevant.
    static func refinedRejectionStatus(
        reason: TranscriptGate.Rejection,
        rmsEnergy: Double,
        diagnosis: AudioDiagnosis?
    ) -> String {
        switch reason {
        case .silence, .empty, .lowConfidence:
            guard let diagnosis, diagnosis.vadAvailable else {
                return rejectionStatus(reason: reason, rmsEnergy: rmsEnergy)
            }
            if diagnosis.speechDetected {
                return rmsEnergy < CapturedAudio.speechFloor
                    ? "Speech detected but too quiet — raise your input level in System Settings → Sound"
                    : "Speech detected but not recognized — try again"
            }
            return "No speech detected — the recording captured only background noise"
        case .placeholder, .hallucinationFilter:
            return rejectionStatus(reason: reason, rmsEnergy: rmsEnergy)
        }
    }
}

/// Speech-presence verdict from the backend's Silero VAD
/// (`POST /v1/audio/diagnose`). `vadAvailable == false` means the VAD failed
/// open — `speechDetected` is not meaningful and callers must fall back to
/// the RMS-based message.
struct AudioDiagnosis: Equatable {
    let speechDetected: Bool
    let speechMs: Int
    let vadAvailable: Bool
}
