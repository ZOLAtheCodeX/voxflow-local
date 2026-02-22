@preconcurrency import AVFoundation
import Foundation

struct CapturedAudio {
    let pcm: Data
    let sampleRate: Double
}

enum AudioCaptureError: Error {
    case noInputNode
    case captureNotRunning
    case converterSetupFailed
}

final class AudioCaptureService {
    static let maxBufferBytes = 10 * 1024 * 1024 // ~5 minutes at 16 kHz mono PCM16
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let bufferLock = NSLock()
    private var pcmBuffer = Data()
    private var isCapturing = false
    private var _bufferLimitReached = false

    var bufferLimitReached: Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _bufferLimitReached
    }

    func startCapture() throws {
        bufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        _bufferLimitReached = false
        bufferLock.unlock()

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target format: 16 kHz, mono, 32-bit float (for AVAudioConverter)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.converterSetupFailed
        }

        // Create the resampling converter (hardware rate → 16kHz mono)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioCaptureError.converterSetupFailed
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            // Calculate output frame count based on sample rate ratio
            let ratio = Self.targetSampleRate / inputFormat.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0 else { return }

            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
                return
            }

            // Convert (resample) the input buffer to 16kHz mono float
            var error: NSError?
            var inputConsumed = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error != nil || outputBuffer.frameLength == 0 { return }

            // Convert float32 samples to Int16 PCM
            guard let floatData = outputBuffer.floatChannelData else { return }
            let frameLength = Int(outputBuffer.frameLength)
            var int16Samples = [Int16]()
            int16Samples.reserveCapacity(frameLength)

            for i in 0..<frameLength {
                let clamped = max(-1.0, min(1.0, floatData[0][i]))
                int16Samples.append(Int16(clamped * Float(Int16.max)))
            }

            let chunk = Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)

            self.bufferLock.lock()
            guard self.pcmBuffer.count < AudioCaptureService.maxBufferBytes else {
                self._bufferLimitReached = true
                self.bufferLock.unlock()
                return
            }
            self.pcmBuffer.append(chunk)
            self.bufferLock.unlock()
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

        bufferLock.lock()
        let captured = pcmBuffer
        bufferLock.unlock()

        return CapturedAudio(pcm: captured, sampleRate: Self.targetSampleRate)
    }
}
