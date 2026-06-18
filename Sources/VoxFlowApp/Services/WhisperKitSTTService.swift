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
        let (floatSamples, appliedGainDB) = await Task.detached {
            // Boost weak input toward a healthy level BEFORE WhisperKit — low
            // amplitude is the dominant empty-transcription cause. The stored
            // PCM / audit rms are untouched, so instrumentation keeps the TRUE
            // input level; only the decoder's copy is normalized.
            AudioGain.normalize(Self.convertPCMInt16ToFloat(audio.pcm))
        }.value
        let conversionLatencyMs = conversionStarted.elapsedMilliseconds()

        let inferenceStarted = ContinuousClock.now
        // Anti-hallucination thresholds made explicit (they match WhisperKit's
        // current defaults by design — pinned here so an upstream default
        // change can't silently weaken the gate). noSpeechThreshold marks a
        // segment silent when noSpeechProb exceeds it AND avgLogprob falls
        // below logProbThreshold; segment noSpeechProb also feeds
        // TranscriptionConfidence regardless of this gate.
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: floatSamples,
            decodeOptions: DecodingOptions(
                language: "en",
                temperatureFallbackCount: 5,
                wordTimestamps: true,
                promptTokens: vocabularyPromptTokens(),
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.6
            )
        )
        let inferenceLatencyMs = inferenceStarted.elapsedMilliseconds()

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMs = started.elapsedMilliseconds()

        let audioDurationS = audio.durationSeconds

        // Coverage-based confidence across ALL segments of ALL results — the
        // old exp(avgLogprob)-of-first-segment estimate scored multi-word
        // noise hallucinations 0.3-0.6, past every downstream gate.
        let segmentSignals = results.flatMap(\.segments).map { seg in
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
            appliedGainDB: appliedGainDB
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
