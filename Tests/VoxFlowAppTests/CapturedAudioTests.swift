import Foundation
import XCTest
@testable import VoxFlowApp

/// `CapturedAudio.durationSeconds` is the single source of truth for capture
/// length — previously the byte/sampleRate formula was copy-pasted across five
/// call sites (two spellings of "2 bytes per Int16").
final class CapturedAudioTests: XCTestCase {

    func testDurationSecondsForOneSecondOf16kPCM16() {
        // 16000 samples/s × 2 bytes/sample = 32000 bytes per second.
        let audio = CapturedAudio(pcm: Data(count: 32000), sampleRate: 16000)
        XCTAssertEqual(audio.durationSeconds, 1.0, accuracy: 0.0001)
    }

    func testDurationSecondsHalfSecond() {
        let audio = CapturedAudio(pcm: Data(count: 16000), sampleRate: 16000)
        XCTAssertEqual(audio.durationSeconds, 0.5, accuracy: 0.0001)
    }

    func testDurationSecondsZeroSampleRateIsFiniteZero() {
        // A 0 sample rate must not produce +inf (which would poison the audit log
        // via JSONSerialization) — clamp to a finite 0.
        let audio = CapturedAudio(pcm: Data(count: 32000), sampleRate: 0)
        XCTAssertEqual(audio.durationSeconds, 0)
        XCTAssertTrue(audio.durationSeconds.isFinite)
    }
}
