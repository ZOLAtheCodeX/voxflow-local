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

    // MARK: - Instrumentation for the empty-capture investigation

    private func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testLeadingSilenceSecondsMeasuresFrontSilence() {
        // 0.5 s of dead-air leading samples, then real signal — the cold-start
        // front-clip hypothesis predicts elevated leading silence on empties.
        var samples = [Int16](repeating: 0, count: 8000)   // 0.5 s @ 16 kHz
        samples += [Int16](repeating: 20_000, count: 1_600)
        let audio = CapturedAudio(pcm: pcm(samples), sampleRate: 16_000)
        XCTAssertEqual(audio.leadingSilenceSeconds, 0.5, accuracy: 0.01)
    }

    func testLeadingSilenceZeroWhenSpeechStartsImmediately() {
        let audio = CapturedAudio(pcm: pcm([Int16](repeating: 20_000, count: 1_600)), sampleRate: 16_000)
        XCTAssertEqual(audio.leadingSilenceSeconds, 0.0, accuracy: 0.001)
    }

    func testLeadingSilenceEqualsDurationWhenAllSilent() {
        let audio = CapturedAudio(pcm: Data(count: 32_000), sampleRate: 16_000) // 1.0 s of zeros
        XCTAssertEqual(audio.leadingSilenceSeconds, 1.0, accuracy: 0.001)
    }

    func testFirstBufferLatencyCarriedThroughInit() {
        let audio = CapturedAudio(pcm: Data(count: 32_000), sampleRate: 16_000, firstBufferLatencyMs: 42)
        XCTAssertEqual(audio.firstBufferLatencyMs, 42)
    }

    func testFirstBufferLatencyDefaultsNil() {
        let audio = CapturedAudio(pcm: Data(count: 32_000), sampleRate: 16_000)
        XCTAssertNil(audio.firstBufferLatencyMs)
    }
}
