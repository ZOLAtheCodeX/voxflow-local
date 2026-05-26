@preconcurrency import WhisperKit
import Foundation
import os.log

@MainActor
final class WhisperKitSTTService {
    private let log = Logger(subsystem: "local.voxflow.app", category: "WhisperKitSTT")
    private var pipe: WhisperKit?
    private(set) var isLoaded = false

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
        let floatSamples = await Task.detached {
            Self.convertPCMInt16ToFloat(audio.pcm)
        }.value
        let conversionLatencyMs = conversionStarted.elapsedMilliseconds()

        let inferenceStarted = ContinuousClock.now
        let results: [TranscriptionResult] = try await pipe.transcribe(
            audioArray: floatSamples,
            decodeOptions: DecodingOptions(
                language: "en",
                wordTimestamps: true
            )
        )
        let inferenceLatencyMs = inferenceStarted.elapsedMilliseconds()

        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMs = started.elapsedMilliseconds()

        let confidence: Double = {
            guard let first = results.first, let seg = first.segments.first else { return 0.0 }
            // avgLogprob is negative; convert to 0-1 range using sigmoid-like mapping
            let prob = exp(Double(seg.avgLogprob))
            return min(1.0, max(0.0, prob))
        }()

        // Apply hallucination filter
        let audioDurationS = Double(audio.pcm.count) / (audio.sampleRate * 2.0) // 2 bytes per Int16 sample
        let isShort = audioDurationS < 3.0
        if HallucinationFilter.isLikelyHallucination(text, shortAudio: isShort) {
            #if DEBUG
            log.info("Filtered hallucination (\(String(format: "%.1f", audioDurationS))s, short=\(isShort)): '\(text.prefix(60))'")
            #else
            log.info("Filtered hallucination (\(String(format: "%.1f", audioDurationS))s, short=\(isShort)): \(text.count) chars")
            #endif
            return TranscribeResponse(
                text: "",
                isFinal: true,
                latencyMs: latencyMs,
                confidenceEstimate: 0.0,
                processingTimeMs: latencyMs,
                stageTimingsMs: [
                    "pcm_to_float": conversionLatencyMs,
                    "stt_inference": inferenceLatencyMs,
                ],
                modelLoadedBeforeRequest: true,
                modelLoadedAfterRequest: true,
                coldStart: false
            )
        }

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
            coldStart: false
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
