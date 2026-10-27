import Foundation
@testable import VoxFlowApp

/// Builds mono PCM16 audio from constant-level segments. Samples alternate
/// `+v` / `-v` with `v = rms * Int16.max`, so each segment's RMS equals `rms`
/// (an even-length segment is exact; odd lengths differ by one sample).
func makeTone(_ segments: [(seconds: Double, rms: Double)], sampleRate: Double = 16_000) -> CapturedAudio {
    var samples: [Int16] = []
    for segment in segments {
        let count = Int((segment.seconds * sampleRate).rounded())
        let level = Int16((segment.rms * Double(Int16.max)).rounded())
        for index in 0..<count {
            samples.append(index % 2 == 0 ? level : -level)
        }
    }
    let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    return CapturedAudio(pcm: pcm, sampleRate: sampleRate)
}
