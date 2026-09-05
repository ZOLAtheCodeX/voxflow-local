import AVFoundation
import XCTest
@testable import VoxFlowApp

final class WhisperKitPerformanceTests: XCTestCase {
    @MainActor
    func testSyntheticWorkload() async throws {
        guard ProcessInfo.processInfo.environment["VOXFLOW_STT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOXFLOW_STT_BENCHMARK=1 to measure the installed local model")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let service = WhisperKitSTTService()
        let loadStart = ContinuousClock.now
        try await service.load(modelFolder: root.appendingPathComponent(
            "models/whisperkit-coreml__openai_whisper-small.en").path)
        defer { service.unload() }
        try report(["benchmark": "model_load", "ms": milliseconds(since: loadStart)])
        let fixtures = ["yes", "tomorrow", "approved", "sentence", "quiet_sentence", "passage"]
        var clips: [String: CapturedAudio] = [:]
        for name in fixtures {
            clips[name] = try load(root.appendingPathComponent("Tests/Fixtures/short_dictation/\(name).wav"))
        }
        _ = try await service.transcribe(try XCTUnwrap(clips["sentence"])) // warm-up excluded
        for glossary in [false, true] {
            service.vocabularyTerms = glossary ? ["meeting", "schedule", "review"] : []
            for name in fixtures {
                let clip = try XCTUnwrap(clips[name])
                for repetition in 0..<3 {
                    let start = ContinuousClock.now
                    let result = try await service.transcribe(clip)
                    try report([
                        "benchmark": "stt", "fixture": name, "glossary": glossary,
                        "repetition": repetition, "ms": milliseconds(since: start),
                        "audio_seconds": clip.durationSeconds, "text": result.text,
                        "confidence": result.confidenceEstimate,
                        "segments": result.segmentCount ?? 0
                    ])
                }
            }
        }
    }

    private func report(_ fields: [String: Any]) throws {
        var row = fields
        row["label"] = ProcessInfo.processInfo.environment["VOXFLOW_BENCHMARK_LABEL"] ?? "unspecified"
        print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    private func load(_ url: URL) throws -> CapturedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        return CapturedAudio(pcm: Data(bytes: channel, count: Int(buffer.frameLength) * 2),
                             sampleRate: file.processingFormat.sampleRate)
    }
}
