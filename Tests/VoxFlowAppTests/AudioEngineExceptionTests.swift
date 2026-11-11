import XCTest
import Foundation
@testable import VoxFlowApp

/// 2026-11-06 crash: AVAudioEngine raised an Objective-C exception
/// (`com.apple.coreaudio.avfaudio`) from Swift on the main thread. Swift
/// cannot catch NSException; AppKit swallowed it, the unwind skipped Swift's
/// cleanup, and the next main-actor isolation check read a stale executor
/// and segfaulted. Every engine call now goes through
/// `AudioCaptureService.guardingEngineCall`, which turns the exception into a
/// Swift error before it can unwind through Swift frames.
final class AudioEngineExceptionTests: XCTestCase {

    private static let avfaudio = NSExceptionName("com.apple.coreaudio.avfaudio")

    func testRaisedEngineExceptionBecomesATypedError() {
        XCTAssertThrowsError(try AudioCaptureService.guardingEngineCall("installTap") {
            NSException(
                name: Self.avfaudio,
                reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
                userInfo: nil
            ).raise()
        }) { error in
            XCTAssertEqual(error as? AudioCaptureError, .engineException(
                call: "installTap",
                name: "com.apple.coreaudio.avfaudio",
                reason: "required condition is false: format.sampleRate == hwFormat.sampleRate"))
        }
    }

    func testCallThatDoesNotRaiseReturnsItsValue() throws {
        XCTAssertEqual(try AudioCaptureService.guardingEngineCall("outputFormat") { 48_000.0 }, 48_000.0)
    }

    /// `engine.start()` throws a Swift error of its own; the guard must pass
    /// it through untouched so callers keep seeing the engine's NSError.
    func testSwiftErrorFromTheCallIsRethrownUnchanged() {
        XCTAssertThrowsError(try AudioCaptureService.guardingEngineCall("start") {
            throw AudioCaptureError.converterSetupFailed
        }) { error in
            XCTAssertEqual(error as? AudioCaptureError, .converterSetupFailed)
        }
    }

    /// The crash itself: a raise inside a main-actor Task (most likely the
    /// hotkey's `Task { @MainActor in startCapture() }`), then a suspension
    /// and an isolation check. Unguarded, the raise unwound through the
    /// Task's job frame and the check read a stale executor record.
    @MainActor
    func testMainActorIsolationSurvivesACaughtEngineException() async {
        let threw = await Task { @MainActor () -> Bool in
            do {
                try AudioCaptureService.guardingEngineCall("installTap") {
                    NSException(
                        name: Self.avfaudio,
                        reason: "required condition is false: nullptr == Tap()",
                        userInfo: nil
                    ).raise()
                }
                return false
            } catch {
                return true
            }
        }.value
        await Task.yield()
        MainActor.assertIsolated()
        XCTAssertTrue(threw)
    }
}
