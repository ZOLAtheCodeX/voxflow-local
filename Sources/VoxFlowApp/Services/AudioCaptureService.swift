import AVFoundation
import Foundation

struct CapturedAudio {
    let pcm: Data
    let sampleRate: Double
}

enum AudioCaptureError: Error {
    case noInputNode
    case captureNotRunning
}

final class AudioCaptureService {
    static let maxBufferBytes = 10 * 1024 * 1024 // ~5 minutes at 16 kHz mono PCM16

    private let engine = AVAudioEngine()
    private var pcmBuffer = Data()
    private var sampleRate: Double = 16_000
    private var isCapturing = false
    private(set) var bufferLimitReached = false

    func startCapture() throws {
        pcmBuffer.removeAll(keepingCapacity: true)
        bufferLimitReached = false

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        sampleRate = inputFormat.sampleRate

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData else { return }

            let frameLength = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            let channels = UnsafeBufferPointer(start: channelData, count: channelCount)

            var int16Samples = [Int16]()
            int16Samples.reserveCapacity(frameLength)

            for frame in 0..<frameLength {
                let mono = channels.map { $0[frame] }.reduce(0, +) / Float(channelCount)
                let clamped = max(-1.0, min(1.0, mono))
                int16Samples.append(Int16(clamped * Float(Int16.max)))
            }

            guard self.pcmBuffer.count < AudioCaptureService.maxBufferBytes else {
                self.bufferLimitReached = true
                return
            }
            self.pcmBuffer.append(Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size))
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
    }

    func stopCapture() throws -> CapturedAudio {
        guard isCapturing else { throw AudioCaptureError.captureNotRunning }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        return CapturedAudio(pcm: pcmBuffer, sampleRate: sampleRate)
    }
}
