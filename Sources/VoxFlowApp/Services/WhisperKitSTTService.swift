@preconcurrency import WhisperKit
import Foundation
import os.log

/// Adapts WhisperKit's tokenizer to the narrow biasing seam.
private struct WhisperKitTokenizerAdapter: VocabularyTokenizing {
    let tokenizer: WhisperTokenizer
    var specialTokenThreshold: Int { tokenizer.specialTokens.specialTokenBegin }
    func encodeText(_ text: String) -> [Int] { tokenizer.encode(text: text) }
}

@MainActor
final class WhisperKitSTTService: ChunkTranscribing {
    private let log = Logger(subsystem: "local.voxflow.app", category: "WhisperKitSTT")
    private var pipe: WhisperKit?
    private(set) var isLoaded = false

    /// R5.1: dictionary terms biasing recognition. Setting invalidates the
    /// cached prompt encoding.
    var vocabularyTerms: [String] = [] {
        didSet { cachedPromptTokens = nil }
    }
    private var cachedPromptTokens: [Int]??

    private func vocabularyPromptTokens() -> [Int]? {
        if let cached = cachedPromptTokens { return cached }
        guard let tokenizer = pipe?.tokenizer else { return nil }
        let tokens = VocabularyBiasing.promptTokens(
            terms: vocabularyTerms,
            tokenizer: WhisperKitTokenizerAdapter(tokenizer: tokenizer)
        )
        cachedPromptTokens = tokens
        return tokens
    }

    nonisolated static func resolveModelFolder(modelsDir: String, modelName: String) -> String {
        (modelsDir as NSString).appendingPathComponent("whisperkit-coreml__\(modelName)")
    }

    /// A non-silent capture that WhisperKit decoded to ZERO segments is worth
    /// one retry on the in-memory audio. Gate on RMS vs the dead-air silence
    /// floor, NOT peak: the old raw-peak >= 0.15 gate excluded exactly the
    /// weak-speech class the gain normalizer targets (field-observed valid
    /// speech at rms ~0.016 peaks well under 0.15), so the captures most
    /// likely to empty were the ones the retry refused (session 29 review).
    /// A decode that already produced segments is never retried.
    nonisolated static func shouldRetryEmptyDecode(
        segmentCount: Int, rmsEnergy: Double, silenceFloor: Double = CapturedAudio.silenceFloor
    ) -> Bool {
        segmentCount == 0 && rmsEnergy >= silenceFloor
    }

    /// Primary decode options. Anti-hallucination thresholds made explicit
    /// (they match WhisperKit's current defaults by design — pinned so an
    /// upstream default change can't silently weaken the gate). Session 29
    /// trims: wordTimestamps OFF (per-word DTW alignment is consumed nowhere
    /// downstream — only segment start/end/noSpeechProb feed confidence —
    /// so it was pure decode failure surface + latency) and 3 temperature
    /// fallbacks instead of 5 (up to 6 full passes on exactly the marginal
    /// clips that already struggle; high-T passes mostly produced garbage
    /// the gate then had to catch).
    nonisolated static func makeDecodeOptions(
        promptTokens: [Int]?, audioDurationSeconds: Double? = nil
    ) -> DecodingOptions {
        // WhisperKit skips windows no longer than windowClipTime. Keep the
        // normal one-second tail guard, but let accepted short captures decode.
        let shortCapture = audioDurationSeconds.map { $0 > 0 && $0 <= 1 } ?? false
        return DecodingOptions(
            language: "en",
            temperatureFallbackCount: 3,
            wordTimestamps: false,
            windowClipTime: shortCapture ? 0 : 1,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    /// Partial-decode detection (session 29 tail-loss class): seconds of
    /// SPEECH-BEARING audio after the last transcribed segment, or nil when
    /// the tail is short (< `minGapSeconds`) or quiet. An early-EOT decode
    /// (transcript covers only the head) used to be silently accepted; the
    /// energy-ratio check keeps trailing silence — a user dawdling before
    /// pressing stop — from false-positive warnings. Ratio-based, so it is
    /// invariant to the uniform gain normalization applied upstream.
    nonisolated static func untranscribedSpeechTail(
        samples: [Float],
        sampleRate: Double,
        lastSegmentEnd: Double,
        minGapSeconds: Double = 2.0
    ) -> Double? {
        guard sampleRate > 0, !samples.isEmpty, lastSegmentEnd >= 0 else { return nil }
        let clipSeconds = Double(samples.count) / sampleRate
        let gap = clipSeconds - lastSegmentEnd
        guard gap >= minGapSeconds else { return nil }

        func rms(_ slice: ArraySlice<Float>) -> Double {
            guard !slice.isEmpty else { return 0 }
            let sum = slice.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (sum / Double(slice.count)).squareRoot()
        }
        let tailStart = min(samples.count, Int(lastSegmentEnd * sampleRate))
        let tailRMS = rms(samples[tailStart...])
        let clipRMS = rms(samples[...])
        // Speech-bearing = the tail carries energy comparable to the clip's
        // own speech level AND is above dead air in absolute terms.
        guard clipRMS > 0, tailRMS >= 0.6 * clipRMS,
              tailRMS >= CapturedAudio.silenceFloor else { return nil }
        return gap
    }

    /// The seg=0 retry must VARY the decode, not replay it byte-identically —
    /// a deterministic failure (gappy PCM) reproduces under identical inputs.
    /// Drop the vocabulary prompt (a known continuation-hallucination
    /// amplifier, per VocabularyBiasing's own notes) and word-timestamp
    /// alignment (consumed nowhere downstream; pure failure surface). The
    /// quality thresholds stay pinned: the retry varies inputs, not gates.
    nonisolated static func retryDecodeOptions(from options: DecodingOptions) -> DecodingOptions {
        var retry = options
        retry.promptTokens = nil
        retry.wordTimestamps = false
        return retry
    }

    func load(modelFolder: String) async throws {
        log.info("Loading WhisperKit model from \(modelFolder)")
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
                prefillCompute: .cpuOnly
            ),
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        pipe = try await WhisperKit(config)
        isLoaded = true
        log.info("WhisperKit model loaded successfully")
    }

    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        guard let pipe else {
            throw WhisperKitSTTError.modelNotLoaded
        }

        let started = ContinuousClock.now
        let conversionStarted = ContinuousClock.now
        let (floatSamples, appliedGainDB, peakAmplitude, rawRMS) = await Task.detached { () -> ([Float], Double, Double, Double) in
            // Boost weak input toward a healthy level BEFORE WhisperKit — low
            // amplitude is the dominant empty-transcription cause. The stored
            // PCM / audit rms are untouched, so instrumentation keeps the TRUE
            // input level; only the decoder's copy is normalized. Peak and rms
            // are raw (pre-gain): peak spots transient-in-silence clips, rms
            // drives the seg=0 retry gate.
            let raw = Self.convertPCMInt16ToFloat(audio.pcm)
            let peak = Double(raw.map { abs($0) }.max() ?? 0)
            let sumSquares = raw.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = raw.isEmpty ? 0 : (sumSquares / Double(raw.count)).squareRoot()
            let (normalized, gainDB) = AudioGain.normalize(raw)
            return (normalized, gainDB, peak, rms)
        }.value
        let conversionLatencyMs = conversionStarted.elapsedMilliseconds()

        // noSpeechThreshold marks a segment silent when noSpeechProb exceeds
        // it AND avgLogprob falls below logProbThreshold; segment noSpeechProb
        // also feeds TranscriptionConfidence regardless of this gate.
        let decodeOptions = Self.makeDecodeOptions(
            promptTokens: vocabularyPromptTokens(), audioDurationSeconds: audio.durationSeconds)
        let inferenceStarted = ContinuousClock.now
        var results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: floatSamples, decodeOptions: decodeOptions)
        // seg=0 retry: non-silent audio that decoded to nothing gets one more
        // attempt on the audio already in memory (no re-recording for the
        // user) — with VARIED options, since a deterministic failure would
        // reproduce under an identical replay.
        if Self.shouldRetryEmptyDecode(
            segmentCount: results.flatMap(\.segments).count, rmsEnergy: rawRMS) {
            try Task.checkCancellation()
            log.info("WhisperKit returned 0 segments on audio with rms \(String(format: "%.4f", rawRMS)) — retrying decode once with varied options")
            results = try await pipe.transcribe(
                audioArray: floatSamples, decodeOptions: Self.retryDecodeOptions(from: decodeOptions))
        }
        let inferenceLatencyMs = inferenceStarted.elapsedMilliseconds()

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMs = started.elapsedMilliseconds()

        let audioDurationS = audio.durationSeconds

        // Coverage-based confidence across ALL segments of ALL results — the
        // old exp(avgLogprob)-of-first-segment estimate scored multi-word
        // noise hallucinations 0.3-0.6, past every downstream gate.
        let allSegments = results.flatMap(\.segments)
        let segmentSignals = allSegments.map { seg in
            TranscriptionConfidence.SegmentSignal(
                startSeconds: Double(seg.start),
                endSeconds: Double(seg.end),
                noSpeechProb: Double(seg.noSpeechProb)
            )
        }
        let confidence = TranscriptionConfidence.estimate(
            segments: segmentSignals,
            text: text,
            audioDurationSeconds: audioDurationS
        )
        // Decode internals for the healthy-RMS-empty investigation: mean
        // no-speech probability across segments (high = the model's own VAD
        // rejected it) and how many segments the decode produced (0 = it
        // produced nothing). nil mean when there are no segments at all.
        let noSpeechProbs = allSegments.map { Double($0.noSpeechProb) }
        let meanNoSpeechProb = noSpeechProbs.isEmpty
            ? nil : noSpeechProbs.reduce(0, +) / Double(noSpeechProbs.count)

        // Partial-decode flag: speech-bearing audio after the last transcribed
        // segment means the decoder stopped early and words were lost.
        let speechTailGap: Double? = allSegments.map({ Double($0.end) }).max().flatMap { lastEnd in
            Self.untranscribedSpeechTail(
                samples: floatSamples,
                sampleRate: audio.sampleRate,
                lastSegmentEnd: lastEnd
            )
        }

        // NOTE: hallucination filtering is intentionally NOT done here. The
        // single ingress `TranscriptGate.evaluate` applies the identical
        // `HallucinationFilter` (and the confidence rules) for EVERY transcript
        // path (quick dictation, cockpit chunks, command lane). Blanking the
        // text here used to pre-empt that gate, so a filtered hallucination
        // reached the audit log mislabeled as `reason:"empty"` instead of
        // `hallucination_filter` — making the two failure modes indistinguishable
        // in the forensics log. Return the real text and let the gate classify.

        #if DEBUG
        log.info("Transcribed in \(latencyMs)ms: '\(text.prefix(80))' (confidence=\(String(format: "%.2f", confidence)))")
        #else
        log.info("Transcribed in \(latencyMs)ms: \(text.count) chars (confidence=\(String(format: "%.2f", confidence)))")
        #endif

        return TranscribeResponse(
            text: text,
            isFinal: true,
            latencyMs: latencyMs,
            confidenceEstimate: confidence,
            processingTimeMs: latencyMs,
            stageTimingsMs: [
                "pcm_to_float": conversionLatencyMs,
                "stt_inference": inferenceLatencyMs,
            ],
            modelLoadedBeforeRequest: true,
            modelLoadedAfterRequest: true,
            coldStart: false,
            appliedGainDB: appliedGainDB,
            meanNoSpeechProb: meanNoSpeechProb,
            segmentCount: allSegments.count,
            peakAmplitude: peakAmplitude,
            speechTailGapSeconds: speechTailGap
        )
    }

    func unload() {
        pipe = nil
        isLoaded = false
        log.info("WhisperKit model unloaded")
    }

    // MARK: - Audio Conversion

    nonisolated static func convertPCMInt16ToFloat(_ pcmData: Data) -> [Float] {
        let sampleCount = pcmData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        return pcmData.withUnsafeBytes { raw in
            let int16Buffer = raw.bindMemory(to: Int16.self)
            return (0..<sampleCount).map { i in
                Float(int16Buffer[i]) / Float(Int16.max)
            }
        }
    }
}

enum WhisperKitSTTError: LocalizedError {
    case modelNotLoaded
    case modelNotFound(path: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "WhisperKit model not loaded"
        case .modelNotFound(let path):
            return "WhisperKit model not found at: \(path)"
        }
    }
}
