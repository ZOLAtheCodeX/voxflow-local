@preconcurrency import AVFoundation
import Foundation
import os

struct CapturedAudio {
    let pcm: Data
    let sampleRate: Double

    /// RMS energy of the PCM16 buffer, normalized to 0.0–1.0.
    /// Silence is typically < 0.005; speech is > 0.02.
    var rmsEnergy: Double {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        return pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var sumSquares: Double = 0
            for i in 0..<sampleCount {
                let normalized = Double(samples[i]) / Double(Int16.max)
                sumSquares += normalized * normalized
            }
            return (sumSquares / Double(sampleCount)).squareRoot()
        }
    }

    /// True if the audio is below the silence threshold (RMS < 0.008).
    var isSilent: Bool {
        rmsEnergy < 0.008
    }
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

    private struct State: Sendable {
        var pcmBuffer = Data()
        var bufferLimitReached = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var isCapturing = false

    var bufferLimitReached: Bool {
        state.withLock { $0.bufferLimitReached }
    }

    func startCapture() throws {
        state.withLock {
            $0.pcmBuffer.removeAll(keepingCapacity: true)
            $0.bufferLimitReached = false
        }

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

            self.state.withLock { state in
                guard state.pcmBuffer.count < AudioCaptureService.maxBufferBytes else {
                    state.bufferLimitReached = true
                    return
                }
                state.pcmBuffer.append(chunk)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    func stopCapture() throws -> CapturedAudio {
        guard isCapturing else { throw AudioCaptureError.captureNotRunning }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        let captured = state.withLock { $0.pcmBuffer }

        return CapturedAudio(pcm: captured, sampleRate: Self.targetSampleRate)
    }
}
