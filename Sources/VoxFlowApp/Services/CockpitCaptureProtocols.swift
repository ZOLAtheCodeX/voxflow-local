import Foundation

/// Start/stop whole-clip audio capture. `AudioCaptureService` conforms as-is.
protocol AudioCapturing: AnyObject {
    /// `onCaptureLive` fires once, on the audio thread, when the FIRST real
    /// buffer arrives — i.e. when the mic is actually delivering audio, not just
    /// when `engine.start()` returned. The capture cue is gated on this so the
    /// "speak now" signal doesn't fire ~150 ms before the hardware is live
    /// (which clipped the front of every utterance).
    func startCapture(onCaptureLive: (@Sendable () -> Void)?) throws
    func stopCapture() throws -> CapturedAudio
}

extension AudioCapturing {
    /// Back-compat for callers that don't need the live signal (e.g. cockpit).
    func startCapture() throws { try startCapture(onCaptureLive: nil) }
}

/// One-shot transcription of a captured clip. `WhisperKitSTTService` conforms as-is.
protocol ChunkTranscribing: AnyObject, Sendable {
    func transcribe(_ audio: CapturedAudio) async throws -> TranscribeResponse
}
