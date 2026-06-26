import Accelerate
@preconcurrency import AVFoundation
import Foundation
import os

struct CapturedAudio {
    let pcm: Data
    let sampleRate: Double

    /// Wall-clock ms from capture start to the first audio buffer the OS
    /// delivered — the cold-start latency the empty-capture investigation needs
    /// to correlate against. nil when not measured (tests, backend STT path).
    let firstBufferLatencyMs: Int?

    init(pcm: Data, sampleRate: Double, firstBufferLatencyMs: Int? = nil) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.firstBufferLatencyMs = firstBufferLatencyMs
    }

    /// Below this RMS the capture is treated as dead-air silence (no usable
    /// signal). Conservative — catches dead/muted mics without rejecting quiet
    /// speakers.
    static let silenceFloor = 0.003
    /// Normal speech sits above this RMS. Between `silenceFloor` and this is the
    /// "present but too weak to decode" band — the actionable mic-hint case.
    static let speechFloor = 0.02

    /// RMS energy of the PCM16 buffer, normalized to 0.0–1.0.
    /// Silence is < `silenceFloor`; speech is > `speechFloor`.
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

    /// True if the audio is below the silence floor — dead-air / dead mic.
    var isSilent: Bool {
        rmsEnergy < CapturedAudio.silenceFloor
    }

    /// Duration of the captured PCM16 buffer in seconds. Single source of truth
    /// for capture length. Guards a non-positive sample rate so it never yields
    /// a non-finite value (which would poison the JSONL audit log).
    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(pcm.count) / (sampleRate * Double(MemoryLayout<Int16>.size))
    }

    /// Seconds of leading dead-air before the first sample at or above the
    /// silence floor. Elevated leading silence on an empty/low-coverage capture
    /// points at cold-start front-clip (the engine was not yet capturing when
    /// the user began speaking) rather than low gain — the distinction the
    /// empty-capture investigation hinges on. Returns the full duration when the
    /// whole clip is below the floor.
    var leadingSilenceSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        let threshold = CapturedAudio.silenceFloor
        let firstVoiced: Int? = pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount where abs(Double(samples[i]) / Double(Int16.max)) >= threshold {
                return i
            }
            return nil
        }
        guard let firstVoiced else { return durationSeconds }
        return Double(firstVoiced) / sampleRate
    }
}

enum AudioCaptureError: Error {
    case noInputNode
    case captureNotRunning
    case converterSetupFailed
    case deviceChanged
}

final class AudioCaptureService: AudioCapturing {
    static let maxBufferBytes = 10 * 1024 * 1024 // ~5 minutes at 16 kHz mono PCM16
    static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "local.voxflow.app", category: "AudioCaptureService")

    private struct State: Sendable {
        var pcmBuffer = Data()
        var bufferLimitReached = false
        // Cold-start instrumentation: when capture armed, and how long until the
        // first OS audio buffer arrived. Kept under the same lock as pcmBuffer
        // because the tap callback runs on the audio thread.
        var captureStartedAt: ContinuousClock.Instant?
        var firstBufferLatencyMs: Int?
        // Fired once when the first real buffer lands, so the caller can gate the
        // "mic is live, speak now" cue on actual hardware readiness. Held under
        // the lock because it's set on the main thread and read on the audio thread.
        var onCaptureLive: (@Sendable () -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var isCapturing = false
    private var deviceChangedDuringCapture = false
    private var configurationObserver: NSObjectProtocol?

    init() {
        // AVAudioEngine stops itself silently when the input device changes
        // (AirPods connect/disconnect). Observe the engine's configuration
        // change so mid-capture device swaps tear down cleanly instead of
        // returning stale audio and leaving the engine inconsistent (S2).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Tear down a capture invalidated by an input-device change. The next
    /// stopCapture() throws `.deviceChanged` exactly once so the caller can
    /// reset its state machine; startCapture() clears the flag.
    func handleConfigurationChange() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        deviceChangedDuringCapture = true
        logger.warning("Audio device configuration changed mid-capture — capture invalidated")
    }

    var bufferLimitReached: Bool {
        state.withLock { $0.bufferLimitReached }
    }

    func startCapture(onCaptureLive: (@Sendable () -> Void)?) throws {
        deviceChangedDuringCapture = false
        state.withLock {
            $0.pcmBuffer.removeAll(keepingCapacity: true)
            $0.bufferLimitReached = false
            $0.captureStartedAt = nil
            $0.firstBufferLatencyMs = nil
            $0.onCaptureLive = onCaptureLive
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

            // Convert float32 samples to Int16 PCM via vDSP (vectorized)
            guard let floatData = outputBuffer.floatChannelData else { return }
            let frameLength = Int(outputBuffer.frameLength)
            guard frameLength > 0 else { return }

            let vLen = vDSP_Length(frameLength)
            var scale = Float(Int16.max)
            var lo = -Float(Int16.max)
            var hi = Float(Int16.max)

            // Build Int16 array via vDSP: scale → clamp → convert
            let int16Samples = [Int16](unsafeUninitializedCapacity: frameLength) { buf, count in
                guard let int16Ptr = buf.baseAddress else { count = 0; return }
                let scaled = [Float](unsafeUninitializedCapacity: frameLength) { fbuf, fcount in
                    guard let fptr = fbuf.baseAddress else { fcount = 0; return }
                    vDSP_vsmul(floatData[0], 1, &scale, fptr, 1, vLen)
                    vDSP_vclip(fptr, 1, &lo, &hi, fptr, 1, vLen)
                    vDSP_vfix16(fptr, 1, int16Ptr, 1, vLen)
                    fcount = frameLength
                }
                count = scaled.count == frameLength ? frameLength : 0
            }

            guard int16Samples.count == frameLength else {
                self.logger.error("vDSP float-to-Int16 conversion failed — discarding chunk")
                return
            }

            let chunk = int16Samples.withUnsafeBufferPointer { Data(buffer: $0) }

            // Detect the first buffer under the lock, capture the live handler,
            // then invoke it OUTSIDE the lock — never run caller code while
            // holding the audio-thread lock.
            let liveCallback: (@Sendable () -> Void)? = self.state.withLock { state in
                let isFirstBuffer = state.firstBufferLatencyMs == nil
                if isFirstBuffer {
                    state.firstBufferLatencyMs = state.captureStartedAt?.elapsedMilliseconds() ?? 0
                }
                if state.pcmBuffer.count < AudioCaptureService.maxBufferBytes {
                    state.pcmBuffer.append(chunk)
                } else {
                    state.bufferLimitReached = true
                }
                return isFirstBuffer ? state.onCaptureLive : nil
            }
            liveCallback?()
        }

        engine.prepare()
        state.withLock { $0.captureStartedAt = ContinuousClock.now }
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        isCapturing = true
    }

    func stopCapture() throws -> CapturedAudio {
        if deviceChangedDuringCapture {
            deviceChangedDuringCapture = false
            throw AudioCaptureError.deviceChanged
        }
        guard isCapturing else { throw AudioCaptureError.captureNotRunning }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        let (captured, firstBufferLatencyMs) = state.withLock { ($0.pcmBuffer, $0.firstBufferLatencyMs) }

        return CapturedAudio(
            pcm: captured,
            sampleRate: Self.targetSampleRate,
            firstBufferLatencyMs: firstBufferLatencyMs
        )
    }
}
