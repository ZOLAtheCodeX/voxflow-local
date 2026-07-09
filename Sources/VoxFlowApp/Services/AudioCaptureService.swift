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

    /// Wall-clock seconds from the FIRST delivered buffer to stopCapture —
    /// what the PCM duration SHOULD be if no buffers were dropped. A material
    /// shortfall (durationSeconds << expectedDurationSeconds) means audio was
    /// lost mid-capture (IO overload, stalled device) — previously invisible
    /// (session 29). nil when unmeasured (tests, no buffer ever arrived).
    let expectedDurationSeconds: Double?

    /// True when the capture hit the ~5-minute PCM cap and later audio was
    /// dropped — the flag used to be write-only and the truncated capture
    /// was decoded/inserted as if complete (session 29 review).
    let bufferLimitReached: Bool

    init(
        pcm: Data,
        sampleRate: Double,
        firstBufferLatencyMs: Int? = nil,
        expectedDurationSeconds: Double? = nil,
        bufferLimitReached: Bool = false
    ) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.firstBufferLatencyMs = firstBufferLatencyMs
        self.expectedDurationSeconds = expectedDurationSeconds
        self.bufferLimitReached = bufferLimitReached
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

    // Internal (not private) so the per-buffer ingest step is unit-testable
    // without constructing the real service's AVAudioEngine.
    struct State: Sendable {
        var pcmBuffer = Data()
        var bufferLimitReached = false
        // Cold-start instrumentation: when capture armed, and how long until the
        // first OS audio buffer arrived. Kept under the same lock as pcmBuffer
        // because the tap callback runs on the audio thread.
        var captureStartedAt: ContinuousClock.Instant?
        var firstBufferLatencyMs: Int?
        // Stamp of the most recent delivered buffer (current generation only),
        // so a mid-capture stall — buffers stop flowing while "recording" — is
        // detectable from outside (session 29: stalls silently truncated).
        var lastBufferAt: ContinuousClock.Instant?
        // Fired once when the first real buffer lands, so the caller can gate the
        // "mic is live, speak now" cue on actual hardware readiness. Held under
        // the lock because it's set on the main thread and read on the audio thread.
        var onCaptureLive: (@Sendable () -> Void)?
        // Monotonic capture identity. `removeTap` does not synchronize with an
        // executing tap block, so a stale callback from the previous capture can
        // run after startCapture resets this state — the tap closure carries the
        // generation it was installed under and `ingest` drops mismatches.
        var generation: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Per-buffer ingest step, called by the tap callback under the state lock.
    /// Returns the live callback exactly once — for the first buffer of the
    /// CURRENT capture generation — so the caller can invoke it outside the
    /// lock. A stale generation is dropped wholesale: no append (old audio must
    /// not leak into the new capture), no latency record (a ~0 value would
    /// poison the cold-start receipts), no live callback (the cue would fire
    /// before the engine is live).
    static func ingest(
        state: inout State,
        chunk: Data,
        generation: UInt64,
        maxBytes: Int = maxBufferBytes
    ) -> (@Sendable () -> Void)? {
        guard state.generation == generation else { return nil }
        state.lastBufferAt = ContinuousClock.now
        let isFirstBuffer = state.firstBufferLatencyMs == nil
        if isFirstBuffer {
            state.firstBufferLatencyMs = state.captureStartedAt?.elapsedMilliseconds() ?? 0
        }
        if state.pcmBuffer.count < maxBytes {
            state.pcmBuffer.append(chunk)
        } else {
            state.bufferLimitReached = true
        }
        return isFirstBuffer ? state.onCaptureLive : nil
    }

    private var isCapturing = false
    private var deviceChangedDuringCapture = false
    private var configurationObserver: NSObjectProtocol?

    /// Per-capture conversion scratch, allocated ONCE at startCapture and
    /// reused by every tap callback. The tap runs inside the audio IO cycle:
    /// per-callback allocations page-fault under memory pressure, and a
    /// page-faulted IO cycle blows its deadline and DROPS input buffers —
    /// observed live as CoreAudio overload reports (io_cycle_usage 1.0,
    /// ~19.6 ms of page faults vs a ~10.7 ms budget) coinciding with
    /// empty-decode capture losses (session 29).
    private final class TapScratch {
        let output: AVAudioPCMBuffer
        let int16: UnsafeMutableBufferPointer<Int16>

        init?(targetFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount) {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return nil }
            output = buffer
            int16 = .allocate(capacity: Int(frameCapacity))
        }

        deinit { int16.deallocate() }
    }

    /// Scale float samples to Int16 range, clamp to ±Int16.max, and convert
    /// into `scratch` — all via vDSP, scaling IN PLACE in `floatData` (the
    /// converter rewrites it next callback anyway) so the hot path allocates
    /// nothing but the returned chunk. Returns nil (never writes out of
    /// bounds) when `frameLength` exceeds the scratch capacity.
    nonisolated static func int16Chunk(
        scalingInPlace floatData: UnsafeMutablePointer<Float>,
        frameLength: Int,
        scratch: UnsafeMutableBufferPointer<Int16>
    ) -> Data? {
        guard frameLength > 0, frameLength <= scratch.count,
              let int16Ptr = scratch.baseAddress else { return nil }
        let vLen = vDSP_Length(frameLength)
        var scale = Float(Int16.max)
        var lo = -Float(Int16.max)
        var hi = Float(Int16.max)
        vDSP_vsmul(floatData, 1, &scale, floatData, 1, vLen)
        vDSP_vclip(floatData, 1, &lo, &hi, floatData, 1, vLen)
        vDSP_vfix16(floatData, 1, int16Ptr, 1, vLen)
        return Data(bytes: int16Ptr, count: frameLength * MemoryLayout<Int16>.size)
    }

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
        state.withLock {
            $0.generation &+= 1
            $0.onCaptureLive = nil
        }
        logger.warning("Audio device configuration changed mid-capture — capture invalidated")
    }

    var bufferLimitReached: Bool {
        state.withLock { $0.bufferLimitReached }
    }

    /// Seconds since the last delivered buffer, or nil before the first
    /// buffer arrives (the CaptureLiveWatchdog owns that phase). Polled by
    /// the coordinator's recording timer to catch MID-capture stalls — the
    /// device stopping delivery without an AVAudioEngineConfigurationChange
    /// used to leave the user speaking into a dead engine (session 29).
    var secondsSinceLastBuffer: Double? {
        state.withLock { $0.lastBufferAt }
            .map { Double($0.elapsedMilliseconds()) / 1000.0 }
    }

    /// RMS of the last `seconds` of the live buffer — the cockpit's
    /// quiet-boundary flush peeks this to cut chunks between words instead
    /// of through them. Snapshot of the tail bytes under the lock, math
    /// outside it.
    func tailRMSEnergy(seconds: Double) -> Double? {
        let tail: Data? = state.withLock { state in
            let bytes = Int(Self.targetSampleRate * seconds) * MemoryLayout<Int16>.size
            guard bytes > 0, state.pcmBuffer.count >= bytes else { return nil }
            return state.pcmBuffer.suffix(bytes)
        }
        return tail.flatMap { Self.tailRMS(of: $0, sampleRate: Self.targetSampleRate, seconds: seconds) }
    }

    /// Pure tail-window rms: nil when the buffer can't cover the window
    /// (too early in the capture to judge a boundary).
    nonisolated static func tailRMS(of pcm: Data, sampleRate: Double, seconds: Double) -> Double? {
        let bytes = Int(sampleRate * seconds) * MemoryLayout<Int16>.size
        guard bytes > 0, pcm.count >= bytes else { return nil }
        return CapturedAudio(pcm: Data(pcm.suffix(bytes)), sampleRate: sampleRate).rmsEnergy
    }

    func startCapture(onCaptureLive: (@Sendable () -> Void)?) throws {
        deviceChangedDuringCapture = false
        let captureGeneration: UInt64 = state.withLock {
            $0.pcmBuffer.removeAll(keepingCapacity: true)
            $0.bufferLimitReached = false
            $0.captureStartedAt = nil
            $0.firstBufferLatencyMs = nil
            $0.lastBufferAt = nil
            $0.onCaptureLive = onCaptureLive
            $0.generation &+= 1
            return $0.generation
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioCaptureError.converterSetupFailed
        }

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

        // Preallocate the conversion scratch once per capture, sized with 4×
        // headroom over the requested tap buffer (the OS is free to deliver
        // larger blocks under load — exactly when allocation-freedom matters).
        let ratio = Self.targetSampleRate / inputFormat.sampleRate
        let expectedOutputFrames = AVAudioFrameCount((4096.0 * ratio).rounded(.up))
        guard let scratch = TapScratch(
            targetFormat: targetFormat,
            frameCapacity: expectedOutputFrames * 4 + 64
        ) else {
            throw AudioCaptureError.converterSetupFailed
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            guard buffer.frameLength > 0 else { return }

            // Hot path: reuse the per-capture output buffer. An oversized OS
            // delivery (beyond the 4× headroom) falls back to a fresh buffer —
            // correctness over allocation-freedom on that rare block.
            let neededFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
            let outputBuffer: AVAudioPCMBuffer
            if neededFrames <= scratch.output.frameCapacity {
                outputBuffer = scratch.output
                outputBuffer.frameLength = 0
            } else {
                guard let fresh = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: neededFrames) else { return }
                outputBuffer = fresh
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

            guard let floatData = outputBuffer.floatChannelData else { return }
            let frameLength = Int(outputBuffer.frameLength)

            // Float32 → Int16 via vDSP, scaling in place, into the reused
            // scratch. The fallback (fresh output buffer beyond scratch size)
            // pays a one-off temp allocation and stays correct.
            let chunk: Data?
            if outputBuffer === scratch.output, frameLength <= scratch.int16.count {
                chunk = Self.int16Chunk(
                    scalingInPlace: floatData[0], frameLength: frameLength, scratch: scratch.int16)
            } else {
                let temp = UnsafeMutableBufferPointer<Int16>.allocate(capacity: frameLength)
                defer { temp.deallocate() }
                chunk = Self.int16Chunk(
                    scalingInPlace: floatData[0], frameLength: frameLength, scratch: temp)
            }

            guard let chunk else {
                self.logger.error("vDSP float-to-Int16 conversion failed — discarding chunk")
                return
            }

            // Ingest under the lock (generation-guarded), then invoke the live
            // handler OUTSIDE the lock — never run caller code while holding
            // the audio-thread lock.
            let liveCallback = self.state.withLock { state in
                Self.ingest(state: &state, chunk: chunk, generation: captureGeneration)
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

        // Bump the generation so any tap block still executing is dropped by
        // `ingest`, and release the live handler — a capture that has stopped
        // must never fire its cue, and the closure (with its captured coordinator
        // machinery) must not linger in shared state across the idle period.
        let (captured, firstBufferLatencyMs, expectedDuration, limitReached) = state.withLock { state -> (Data, Int?, Double?, Bool) in
            state.generation &+= 1
            state.onCaptureLive = nil
            // Wall-clock from FIRST buffer to now — the span the PCM should
            // cover if no buffers were dropped mid-capture.
            let expected: Double? = state.captureStartedAt.flatMap { startedAt in
                state.firstBufferLatencyMs.map { firstLatency in
                    max(0, Double(startedAt.elapsedMilliseconds() - firstLatency) / 1000.0)
                }
            }
            return (state.pcmBuffer, state.firstBufferLatencyMs, expected, state.bufferLimitReached)
        }

        return CapturedAudio(
            pcm: captured,
            sampleRate: Self.targetSampleRate,
            firstBufferLatencyMs: firstBufferLatencyMs,
            expectedDurationSeconds: expectedDuration,
            bufferLimitReached: limitReached
        )
    }
}
