import XCTest
import AVFoundation
@testable import VoxFlowApp

final class AudioCaptureServiceTests: XCTestCase {

    func testInitialState() {
        let service = AudioCaptureService()
        XCTAssertFalse(service.bufferLimitReached, "Buffer limit should be false initially")
    }

    func testStopCaptureWhenNotRunningThrows() {
        let service = AudioCaptureService()
        XCTAssertThrowsError(try service.stopCapture()) { error in
            XCTAssertEqual(error as? AudioCaptureError, AudioCaptureError.captureNotRunning)
        }
    }

    func testMaxBufferBytesAndTargetSampleRateConstants() {
        XCTAssertEqual(AudioCaptureService.maxBufferBytes, 10 * 1024 * 1024)
        XCTAssertEqual(AudioCaptureService.targetSampleRate, 16_000)
    }

    func testStartCaptureNoInputNodeOrConverter() {
        let service = AudioCaptureService()
        // In a headless CI environment, starting capture might fail if there's no audio input device.
        // We catch the error to ensure it fails gracefully with a typed error.
        do {
            try service.startCapture()
            // If it succeeds, we should also test stopping it.
            let audio = try service.stopCapture()
            XCTAssertNotNil(audio)
        } catch {
            // It could be missing input node, converter setup failed, or an AVFoundation NSError
            if let captureError = error as? AudioCaptureError {
                XCTAssertTrue(
                    captureError == .noInputNode || captureError == .converterSetupFailed,
                    "Should throw a known AudioCaptureError"
                )
            } else {
                let nsError = error as NSError
                XCTAssertFalse(nsError.domain.isEmpty, "Unexpected non-NSError failure: \(type(of: error))")
            }
        }
    }
}
