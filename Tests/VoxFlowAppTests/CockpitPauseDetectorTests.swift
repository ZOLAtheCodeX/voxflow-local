import XCTest
@testable import VoxFlowApp

final class CockpitPauseDetectorTests: XCTestCase {

    func test_frameRMSValues_uses_20ms_frames_with_partial_last_frame() {
        let audio = makeTone([(seconds: 0.05, rms: 0.08)])   // 800 samples = 320 + 320 + 160
        let frames = audio.frameRMSValues()
        XCTAssertEqual(frames.count, 3)
        for value in frames { XCTAssertEqual(value, 0.08, accuracy: 0.001) }
    }

    func test_empty_pcm() {
        let audio = CapturedAudio(pcm: Data(), sampleRate: 16_000)
        XCTAssertEqual(audio.frameRMSValues(), [])
        XCTAssertEqual(audio.leadingQuietSeconds(threshold: 0.01), 0)
        XCTAssertEqual(audio.trailingQuietSeconds(threshold: 0.01), 0)
        XCTAssertNil(CockpitPauseDetector.quietThreshold(for: audio))
    }

    func test_all_quiet_returns_full_duration() {
        let audio = makeTone([(seconds: 1.0, rms: 0.0)])
        XCTAssertNil(CockpitPauseDetector.quietThreshold(for: audio))
        XCTAssertEqual(audio.leadingQuietSeconds(threshold: 0.01), audio.durationSeconds)
        XCTAssertEqual(audio.trailingQuietSeconds(threshold: 0.01), audio.durationSeconds)
    }

    func test_leading_and_trailing_quiet_are_measured() throws {
        let audio = makeTone([(seconds: 1.0, rms: 0.0), (seconds: 2.0, rms: 0.08), (seconds: 0.5, rms: 0.0)])
        let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
        XCTAssertEqual(threshold, 0.024, accuracy: 0.0005)
        XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 1.0, accuracy: 0.02)
        XCTAssertEqual(audio.trailingQuietSeconds(threshold: threshold), 0.5, accuracy: 0.02)
    }

    func test_weak_speech_is_not_quiet() throws {
        let audio = makeTone([(seconds: 3.0, rms: 0.01)])
        let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
        XCTAssertEqual(threshold, 0.0045, accuracy: 0.0002)
        XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 0)
    }

    func test_room_noise_inside_normal_speech_is_quiet() throws {
        let audio = makeTone([(seconds: 1.0, rms: 0.005), (seconds: 2.0, rms: 0.08)])
        let threshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: audio))
        XCTAssertEqual(audio.leadingQuietSeconds(threshold: threshold), 1.0, accuracy: 0.02)
    }

    func test_pure_noise_chunk_is_entirely_quiet() {
        XCTAssertNil(CockpitPauseDetector.quietThreshold(for: makeTone([(seconds: 2.0, rms: 0.005)])))
    }

    func test_each_chunk_is_judged_against_its_own_level() throws {
        let loud = makeTone([(seconds: 2.0, rms: 0.2)])
        let weak = makeTone([(seconds: 2.0, rms: 0.01)])
        let loudThreshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: loud))
        let weakThreshold = try XCTUnwrap(CockpitPauseDetector.quietThreshold(for: weak))
        XCTAssertEqual(loudThreshold, 0.06, accuracy: 0.001)
        XCTAssertEqual(weak.leadingQuietSeconds(threshold: loudThreshold), weak.durationSeconds,
                       "under the loud chunk's level the weak chunk would read as silence")
        XCTAssertEqual(weak.leadingQuietSeconds(threshold: weakThreshold), 0)
    }
}
