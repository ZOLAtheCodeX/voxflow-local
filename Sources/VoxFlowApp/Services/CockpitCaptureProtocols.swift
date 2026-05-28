import Foundation

/// Start/stop whole-clip audio capture. `AudioCaptureService` conforms as-is.
protocol AudioCapturing: AnyObject {
    func startCapture() throws
    func stopCapture() throws -> CapturedAudio
}

/// One-shot transcription of a captured clip. `WhisperKitSTTService` conforms as-is.
protocol ChunkTranscribing: AnyObject, Sendable {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse
}
