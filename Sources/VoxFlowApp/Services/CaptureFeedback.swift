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
}
