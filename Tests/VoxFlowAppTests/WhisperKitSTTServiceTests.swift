import XCTest
@testable import VoxFlowApp

final class WhisperKitSTTServiceTests: XCTestCase {

    // MARK: - PCM conversion

    func testConvertPCMInt16ToFloat() {
        // Silence: all zeros
        let silence = Data(repeating: 0, count: 4) // 2 samples of Int16(0)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(silence)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 0.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001)
    }

    func testConvertPCMMaxPositive() {
        // Int16.max = 32767
        var sample = Int16.max
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 1.0, accuracy: 0.001)
    }

    func testConvertPCMMaxNegative() {
        // Int16.min = -32768
        var sample = Int16.min
        let data = Data(bytes: &sample, count: 2)
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], -1.0, accuracy: 0.001)
    }

    func testConvertPCMOddByteCountTruncates() {
        // 3 bytes -> only 1 complete Int16 sample (2 bytes), last byte dropped
        let data = Data([0x00, 0x00, 0xFF])
        let result = WhisperKitSTTService.convertPCMInt16ToFloat(data)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - seg=0 retry decision

    /// Session 29 review: the old gate (raw pre-gain peak >= 0.15) excluded
    /// exactly the weak-speech class the gain fix targets — field-observed
    /// valid speech at rms ~0.016 peaks well under 0.15 raw, so the captures
    /// most likely to decode empty were the ones the retry refused. The gate
    /// is now rms above the dead-air silence floor: any non-silent empty
    /// decode earns the retry.
    func testRetriesEmptyDecodeForAnyNonSilentAudio() {
        // The previously-excluded weak-speech class → retry.
        XCTAssertTrue(WhisperKitSTTService.shouldRetryEmptyDecode(segmentCount: 0, rmsEnergy: 0.016))
        // Healthy speech level → retry.
        XCTAssertTrue(WhisperKitSTTService.shouldRetryEmptyDecode(segmentCount: 0, rmsEnergy: 0.07))
        // Dead-air silence → genuinely nothing to decode, do NOT retry.
        XCTAssertFalse(WhisperKitSTTService.shouldRetryEmptyDecode(segmentCount: 0, rmsEnergy: 0.002))
        // Already produced segments → never retry (the happy path is untouched).
        XCTAssertFalse(WhisperKitSTTService.shouldRetryEmptyDecode(segmentCount: 2, rmsEnergy: 0.07))
    }

    func testRetryThresholdBoundaryIsSilenceFloor() {
        XCTAssertTrue(WhisperKitSTTService.shouldRetryEmptyDecode(
            segmentCount: 0, rmsEnergy: CapturedAudio.silenceFloor))
        XCTAssertFalse(WhisperKitSTTService.shouldRetryEmptyDecode(
            segmentCount: 0, rmsEnergy: CapturedAudio.silenceFloor - 0.0001))
    }

    /// Primary decode options (session 29 review): word-timestamp alignment
    /// is consumed NOWHERE downstream (grep-verified — only segment-level
    /// start/end/noSpeechProb feed TranscriptionConfidence), so it is pure
    /// decode failure surface + latency; temperatureFallbackCount 5 meant up
    /// to 6 full decode passes on exactly the marginal clips that already
    /// struggle. Quality thresholds stay pinned.
    func testPrimaryDecodeOptionsAreLean() {
        let options = WhisperKitSTTService.makeDecodeOptions(promptTokens: nil)
        XCTAssertFalse(options.wordTimestamps)
        XCTAssertEqual(options.temperatureFallbackCount, 3)
        XCTAssertEqual(options.noSpeechThreshold, 0.6)
        XCTAssertEqual(options.compressionRatioThreshold, 2.4)
        XCTAssertEqual(options.logProbThreshold, -1.0)
    }

    func testAcceptedShortCapturesReachTheDecoderWithoutChangingLongClipTailGuard() {
        for duration in [0.3, 0.48, 0.94, 0.999, 1.0] {
            let options = WhisperKitSTTService.makeDecodeOptions(
                promptTokens: [1, 2], audioDurationSeconds: duration)
            XCTAssertEqual(options.windowClipTime, 0, "duration=\(duration)")
            XCTAssertEqual(WhisperKitSTTService.retryDecodeOptions(from: options).windowClipTime, 0)
            XCTAssertEqual(options.noSpeechThreshold, 0.6)
        }
        for duration in [1.001, 2.3, 30, 0, -.infinity, .nan] {
            XCTAssertEqual(WhisperKitSTTService.makeDecodeOptions(
                promptTokens: nil, audioDurationSeconds: duration).windowClipTime, 1)
        }
        XCTAssertEqual(WhisperKitSTTService.makeDecodeOptions(promptTokens: nil).windowClipTime, 1)
    }

    /// The retry must VARY the decode, not replay it byte-identically: a
    /// deterministic decode failure (gappy PCM) reproduces under identical
    /// options, so the second attempt drops the vocabulary prompt (a known
    /// continuation-hallucination amplifier) and word-timestamp alignment
    /// (unused downstream; pure failure surface).
    func testRetryOptionsDropPromptAndWordTimestamps() {
        var primary = WhisperKitSTTService.makeDecodeOptions(promptTokens: [1, 2, 3])
        primary.wordTimestamps = true

        let retry = WhisperKitSTTService.retryDecodeOptions(from: primary)

        XCTAssertNil(retry.promptTokens)
        XCTAssertFalse(retry.wordTimestamps)
        // Quality thresholds stay pinned — the retry varies inputs, not gates.
        XCTAssertEqual(retry.noSpeechThreshold, primary.noSpeechThreshold)
        XCTAssertEqual(retry.compressionRatioThreshold, primary.compressionRatioThreshold)
        XCTAssertEqual(retry.logProbThreshold, primary.logProbThreshold)
    }

    // MARK: - Untranscribed speech tail (partial decode detection)

    /// Session 29 review: an early-EOT decode (transcript covers only the
    /// head of the audio) was silently accepted — the tail of the dictation
    /// vanished with no signal. The detector flags a tail that (a) is long
    /// enough to matter and (b) actually carries speech-level energy relative
    /// to the clip, so trailing SILENCE (user dawdles before stop) never
    /// false-positives.
    func testSpeechBearingTailIsDetected() {
        // 4 s clip at constant amplitude; segments end at 2.0 s — the last
        // 2 s are equally loud speech the decoder never transcribed.
        let samples = [Float](repeating: 0.1, count: 4 * 16_000)
        let tail = WhisperKitSTTService.untranscribedSpeechTail(
            samples: samples, sampleRate: 16_000, lastSegmentEnd: 2.0)
        XCTAssertNotNil(tail)
        XCTAssertEqual(tail ?? 0, 2.0, accuracy: 0.05)
    }

    func testSilentTailIsNotFlagged() {
        // 2 s speech then 2 s near-silence: the gap is dawdle, not lost words.
        var samples = [Float](repeating: 0.1, count: 2 * 16_000)
        samples += [Float](repeating: 0.001, count: 2 * 16_000)
        XCTAssertNil(WhisperKitSTTService.untranscribedSpeechTail(
            samples: samples, sampleRate: 16_000, lastSegmentEnd: 2.0))
    }

    func testShortTailIsNotFlagged() {
        // Only 0.5 s untranscribed — below the minimum gap worth warning about.
        let samples = [Float](repeating: 0.1, count: 4 * 16_000)
        XCTAssertNil(WhisperKitSTTService.untranscribedSpeechTail(
            samples: samples, sampleRate: 16_000, lastSegmentEnd: 3.5))
    }

    func testFullCoverageHasNoTail() {
        let samples = [Float](repeating: 0.1, count: 4 * 16_000)
        XCTAssertNil(WhisperKitSTTService.untranscribedSpeechTail(
            samples: samples, sampleRate: 16_000, lastSegmentEnd: 4.0))
    }

    // MARK: - Model path resolution

    func testResolveModelFolder() {
        let modelsDir = "/tmp/test-models"
        let folder = WhisperKitSTTService.resolveModelFolder(
            modelsDir: modelsDir,
            modelName: "openai_whisper-small.en"
        )
        XCTAssertEqual(folder, "/tmp/test-models/whisperkit-coreml__openai_whisper-small.en")
    }
}
