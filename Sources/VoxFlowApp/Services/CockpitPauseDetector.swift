import Foundation

extension CapturedAudio {
    /// Frame length used for pause detection: 20 ms.
    private static let quietFrameSeconds = 0.02

    /// Samples per detection frame, or nil when the clip cannot be framed.
    private var quietFrameLength: Int? {
        guard sampleRate > 0, !pcm.isEmpty else { return nil }
        return max(1, Int((sampleRate * CapturedAudio.quietFrameSeconds).rounded()))
    }

    /// RMS of each consecutive 20 ms frame, normalized like `rmsEnergy`
    /// (sample / Int16.max). Frames start at sample 0; the last frame may be
    /// partial and contributes its own RMS. Empty PCM or a non-positive sample
    /// rate gives `[]`.
    func frameRMSValues() -> [Double] {
        guard let frameLength = quietFrameLength else { return [] }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        return pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var values: [Double] = []
            values.reserveCapacity(sampleCount / frameLength + 1)
            var start = 0
            while start < sampleCount {
                let end = min(start + frameLength, sampleCount)
                var sumSquares = 0.0
                for i in start..<end {
                    let normalized = Double(samples[i]) / Double(Int16.max)
                    sumSquares += normalized * normalized
                }
                values.append((sumSquares / Double(end - start)).squareRoot())
                start = end
            }
            return values
        }
    }

    /// Seconds of consecutive frames with RMS below `threshold`, counted from
    /// the start of the clip. Exactly `durationSeconds` when every frame is
    /// quiet; 0 when the clip is empty.
    func leadingQuietSeconds(threshold: Double) -> Double {
        quietSeconds(threshold: threshold, fromEnd: false)
    }

    /// Same as `leadingQuietSeconds`, counted back from the end of the clip.
    func trailingQuietSeconds(threshold: Double) -> Double {
        quietSeconds(threshold: threshold, fromEnd: true)
    }

    private func quietSeconds(threshold: Double, fromEnd: Bool) -> Double {
        let frames = frameRMSValues()
        guard !frames.isEmpty, let frameLength = quietFrameLength else { return 0 }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        let ordered = fromEnd ? Array(frames.reversed()) : frames
        var quietFrames = 0
        for value in ordered {
            guard value < threshold else { break }
            quietFrames += 1
        }
        if quietFrames == frames.count { return durationSeconds }
        // Only the final frame can be partial; it is first when counting from the end.
        let partial = sampleCount % frameLength
        var samples = quietFrames * frameLength
        if fromEnd, quietFrames > 0, partial != 0 {
            samples -= frameLength - partial
        }
        return Double(samples) / sampleRate
    }
}

/// Per-chunk pause detection for cockpit long-form capture. Each chunk is
/// judged against its own loudness, so a quiet speaker's pauses and a loud
/// speaker's pauses are both found.
enum CockpitPauseDetector {
    /// The RMS below which a frame of `audio` counts as quiet, or nil when the
    /// whole chunk is quiet (its 95th-percentile frame is within 3x the silence
    /// floor, so there is no speech to measure a pause against).
    static func quietThreshold(for audio: CapturedAudio) -> Double? {
        let frames = audio.frameRMSValues()
        guard !frames.isEmpty else { return nil }
        let sorted = frames.sorted()
        let n = sorted.count
        // Nearest-rank 95th percentile over unweighted frame values.
        let rank = Int((0.95 * Double(n)).rounded(.up))
        let p95 = sorted[min(n - 1, max(0, rank - 1))]
        guard p95 >= CapturedAudio.silenceFloor * 3 else { return nil }
        return max(CapturedAudio.silenceFloor * 1.5, 0.3 * p95)
    }
}
