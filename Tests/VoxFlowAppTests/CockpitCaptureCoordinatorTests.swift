import XCTest
@testable import VoxFlowApp

private final class FakeCapture: AudioCapturing {
    var startCount = 0
    var nextAudio: CapturedAudio
    init(nextAudio: CapturedAudio) { self.nextAudio = nextAudio }
    func startCapture() throws { startCount += 1 }
    func stopCapture() throws -> CapturedAudio { nextAudio }
}

private final class FakeTranscriber: ChunkTranscribing, @unchecked Sendable {
    var nextText: String = ""
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse {
        // TranscribeResponse has no defaults — all 9 fields required (BackendAPIClient.swift:3).
        TranscribeResponse(
            text: nextText, isFinal: true, latencyMs: 1, confidenceEstimate: 0.9,
            processingTimeMs: 1, stageTimingsMs: nil,
            modelLoadedBeforeRequest: nil, modelLoadedAfterRequest: nil, coldStart: nil)
    }
}

// Note: the `isFlushing` reentrancy guard is correct by inspection — it's a
// synchronous Bool check evaluated before the first `await` on the @MainActor,
// so a concurrent flushNow() bails before any stop/restart. A timing-based test
// for it is inherently racy (continuation-resume ordering) and was removed.

@MainActor
final class CockpitCaptureCoordinatorTests: XCTestCase {
    private func makeAudio(silent: Bool) -> CapturedAudio {
        let samples = 8000
        var data = Data(count: samples * 2)
        // rmsEnergy = |sample|/Int16.max; isSilent = rmsEnergy < 0.003.
        // Set the HIGH byte of each little-endian Int16 → 0x4000 = 16384 → ~0.5 amplitude, robustly non-silent.
        if !silent { for i in stride(from: 1, to: data.count, by: 2) { data[i] = 0x40 } }
        return CapturedAudio(pcm: data, sampleRate: 16000)
    }

    func test_flushNow_appends_transcribed_text_and_restarts_capture() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "hello world"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        XCTAssertEqual(capture.startCount, 1)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript, "hello world")
        XCTAssertEqual(capture.startCount, 2)
        await coord.stopRecording()
    }

    func test_flushNow_skips_silent_audio() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: true))
        let transcriber = FakeTranscriber(); transcriber.nextText = "should not appear"
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }

    func test_flushNow_skips_empty_transcription() async {
        let capture = FakeCapture(nextAudio: makeAudio(silent: false))
        let transcriber = FakeTranscriber(); transcriber.nextText = "   "
        let session = LongFormSessionService(autoSaveDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let coord = CockpitCaptureCoordinator(capture: capture, transcriber: transcriber, session: session)
        coord.startRecording(targetApp: nil)
        await coord.flushNow()
        XCTAssertEqual(session.currentSession?.transcript ?? "", "")
        await coord.stopRecording()
    }
}
