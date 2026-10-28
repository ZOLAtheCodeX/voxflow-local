import AVFoundation
import XCTest
@testable import VoxFlowApp

/// Opt-in, on-device model check. No microphone, insertion service, backend,
/// or model download is used. Run with VOXFLOW_WHISPERKIT_GOLDEN=1.
final class WhisperKitShortCaptureIntegrationTests: XCTestCase {
    @MainActor
    func testShortSpeechAndNoSpeechThroughActualTranscriber() async throws {
        guard ProcessInfo.processInfo.environment["VOXFLOW_WHISPERKIT_GOLDEN"] == "1" else {
            throw XCTSkip("Set VOXFLOW_WHISPERKIT_GOLDEN=1 to use the local WhisperKit model")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = WhisperKitSTTService()
        try await service.load(modelFolder: root.appendingPathComponent(
            "models/whisperkit-coreml__openai_whisper-small.en").path)
        defer { service.unload() }

        for expected in ["yes", "tomorrow", "approved"] {
            let file = root.appendingPathComponent("Tests/Fixtures/short_dictation/\(expected).wav")
            let audio = try loadPCM(file)
            XCTAssertGreaterThanOrEqual(audio.durationSeconds, TranscriptGate.minAudioSeconds)
            XCTAssertLessThan(audio.durationSeconds, 1)
            XCTAssertFalse(audio.isSilent)

            let result = try await service.transcribe(audio)
            let words = result.text.lowercased().split { !$0.isLetter }.map(String.init)
            XCTAssertEqual(words, [expected], "Short speech must reach the decoder: \(expected)")
            let expectedVerdict: TranscriptGate.Verdict = expected == "yes"
                ? .rejected(reason: .hallucinationFilter) : .accepted
            // The existing short-greeting filter intentionally rejects "yes".
            // Its recognition is still checked above; do not weaken that gate.
            XCTAssertEqual(TranscriptGate.evaluate(
                text: result.text, confidence: result.confidenceEstimate,
                audioDurationSeconds: audio.durationSeconds), expectedVerdict)
        }

        // The same short duration with silence or above-floor random noise
        // must still produce no insertable speech. Exercise the existing gate.
        for name in ["silence_3s", "ambient_noise_4s"] {
            let file = root.appendingPathComponent("backend/tests/fixtures/golden_clips/\(name).wav")
            let fullAudio = try loadPCM(file)
            let shortAudio = CapturedAudio(
                pcm: Data(fullAudio.pcm.prefix(16_000)), sampleRate: 16_000)
            if shortAudio.isSilent { continue } // the real capture path stops before STT
            let result = try await service.transcribe(shortAudio)
            print("synthetic noise \(name): text=\(result.text), confidence=\(result.confidenceEstimate), noSpeech=\(result.meanNoSpeechProb ?? -1), rms=\(shortAudio.rmsEnergy)")
            XCTAssertNotEqual(TranscriptGate.evaluate(
                text: result.text, confidence: result.confidenceEstimate,
                audioDurationSeconds: shortAudio.durationSeconds), .accepted, name)
        }

        // A longer clip exercises the existing end-of-window suppression.
        let fullAudio = try loadPCM(root.appendingPathComponent(
            "backend/tests/fixtures/golden_clips/schedule_phrase.wav"))
        let result = try await service.transcribe(fullAudio)
        XCTAssertEqual(result.text.lowercased().split { !$0.isLetter }.map(String.init),
                       ["thank", "you", "for", "your", "help"])
    }

    private func loadPCM(_ url: URL) throws -> CapturedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.int16ChannelData?[0])
        return CapturedAudio(
            pcm: Data(bytes: channel, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size),
            sampleRate: file.processingFormat.sampleRate)
    }
}
