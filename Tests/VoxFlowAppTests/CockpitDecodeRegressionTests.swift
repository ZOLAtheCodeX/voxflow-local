import AVFoundation
import XCTest
@testable import VoxFlowApp

/// Real-model regression for the 2026-10-27 cockpit acceptance failures.
/// Clips come from Tests/Fixtures/cockpit_decode/make_clips.py (`say` speech
/// mixed with pink room noise). With the vocabulary prompt, speech followed by
/// quiet decoded to "(" or "The vendor is" and the words were lost; noise alone
/// decoded to "(water rushing)" and was accepted. Run with
/// VOXFLOW_WHISPERKIT_GOLDEN=1; no network or model download is used.
@MainActor
final class CockpitDecodeRegressionTests: XCTestCase {
    func testSpeechThenQuietSurvivesTheVocabularyPromptAndNoiseIsRejected() async throws {
        guard ProcessInfo.processInfo.environment["VOXFLOW_WHISPERKIT_GOLDEN"] == "1" else {
            throw XCTSkip("Set VOXFLOW_WHISPERKIT_GOLDEN=1 to use the local WhisperKit model")
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let service = WhisperKitSTTService()
        try await service.load(modelFolder: root.appendingPathComponent(
            "models/whisperkit-coreml__openai_whisper-small.en").path)
        defer { service.unload() }
        // The glossary the acceptance run used (the user's dictionary terms).
        service.vocabularyTerms = ["HIPAA", "GDPR", "CIPT"]
        let fixtures = root.appendingPathComponent("Tests/Fixtures/cockpit_decode")

        for name in ["speech_then_quiet_normal", "speech_then_quiet_weak"] {
            let audio = try loadPCM(fixtures.appendingPathComponent("\(name).wav"))
            let result = try await service.transcribe(audio)
            let admission = TranscriptGate.admit(
                text: result.text, confidence: result.confidenceEstimate,
                audioDurationSeconds: audio.durationSeconds)
            XCTAssertEqual(admission.verdict, .accepted, "\(name): '\(result.text)'")
            XCTAssertTrue(
                admission.text.lowercased().contains("review date for each one"),
                "\(name) lost its speech: '\(admission.text)'")
        }

        let noise = try loadPCM(fixtures.appendingPathComponent("room_noise_6s.wav"))
        let noiseResult = try await service.transcribe(noise)
        XCTAssertNotEqual(
            TranscriptGate.admit(
                text: noiseResult.text, confidence: noiseResult.confidenceEstimate,
                audioDurationSeconds: noise.durationSeconds).verdict,
            .accepted, "room noise must not reach a transcript: '\(noiseResult.text)'")
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
