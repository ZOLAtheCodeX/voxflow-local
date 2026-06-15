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
    /// RMS ceiling under which captured audio counts as "present but weak":
    /// above the hard silence floor (`CapturedAudio.isSilent`, 0.003) yet well
    /// below normal speech (~0.02, per `CapturedAudio`). An empty/low-confidence
    /// transcript whose audio sits in this band points at a muffled or low-gain
    /// microphone rather than genuine silence.
    static let weakInputCeiling = 0.02

    /// Map a `TranscriptGate` rejection reason plus the captured audio energy to
    /// the status line shown to the user. Only the reasons that can stem from a
    /// weak input (`empty`, `low_confidence`) are eligible for the mic hint;
    /// `hallucination_filter` and `placeholder` are content the model invented,
    /// where input level is irrelevant.
    static func rejectionStatus(reason: String, rmsEnergy: Double) -> String {
        switch reason {
        case "empty", "low_confidence":
            return rmsEnergy < weakInputCeiling
                ? "Very low mic level — check your input in System Settings → Sound"
                : "No speech detected — try again"
        default:
            return "No speech detected — try again"
        }
    }
}
