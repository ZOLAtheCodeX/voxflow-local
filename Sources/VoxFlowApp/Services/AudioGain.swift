import Foundation

/// Decoder-side gain normalization for the dictation capture path.
///
/// The dominant cause of empty transcriptions (diagnosed from audit receipts:
/// rms clustered at ~0.02, the speech floor) is low input amplitude — WhisperKit
/// marks audio that quiet as "no speech" and returns an empty string. This
/// boosts weak audio toward a healthy level BEFORE the decoder sees it.
///
/// Applied ONLY to the float copy handed to WhisperKit — never to the stored
/// PCM / audit RMS, which must keep recording the TRUE input level so the
/// instrumentation stays honest.
enum AudioGain {
    /// Normalize toward `targetRMS`, bounded by `maxGainDB`.
    /// - Never attenuates or boosts already-healthy captures (gain ≤ 1 → no-op),
    ///   so it can't degrade captures that already decode fine.
    /// - Bounded by `maxGainDB` so it can't amplify room noise without limit.
    /// - Output clamped to [-1, 1] so transients can't overflow.
    /// - Returns the (possibly) scaled samples and the gain actually applied (dB).
    /// `silenceFloor` (matches `CapturedAudio.silenceFloor`): below this RMS the
    /// signal is genuine dead-air noise — leave it untouched rather than amplify
    /// it toward speech level. We deliberately do NOT guard at the *speech* floor
    /// (0.02): valid weak speech was observed below it (rms 0.016), so a
    /// speech-floor guard would re-break the empty-capture fix.
    static func normalize(
        _ samples: [Float],
        targetRMS: Float = 0.1,
        maxGainDB: Float = 18,
        silenceFloor: Float = 0.003
    ) -> (samples: [Float], appliedGainDB: Double) {
        guard !samples.isEmpty else { return (samples, 0) }

        var sumSquares = 0.0
        for s in samples { sumSquares += Double(s) * Double(s) }
        let rms = (sumSquares / Double(samples.count)).squareRoot()
        guard rms >= Double(silenceFloor) else { return (samples, 0) }

        let desired = Double(targetRMS) / rms
        guard desired > 1.0 else { return (samples, 0) }   // already healthy

        let maxGain = pow(10.0, Double(maxGainDB) / 20.0)
        let gain = min(desired, maxGain)
        let g = Float(gain)
        let scaled = samples.map { Swift.max(-1.0, Swift.min(1.0, $0 * g)) }
        return (scaled, 20.0 * log10(gain))
    }
}
