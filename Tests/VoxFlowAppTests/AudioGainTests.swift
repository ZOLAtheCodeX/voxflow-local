import XCTest
@testable import VoxFlowApp

/// Decoder-side gain normalization: the dominant empty-transcription cause is
/// low input amplitude (rms clustered at ~0.02, the speech floor). Boost weak
/// audio toward a healthy level before WhisperKit, bounded so it can't amplify
/// room noise without limit and never touching already-healthy captures.
final class AudioGainTests: XCTestCase {

    private func rms(_ s: [Float]) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s.map { Double($0) * Double($0) }.reduce(0, +) / Double(s.count)).squareRoot()
    }

    func testBoostsWeakAudioTowardTarget() {
        let weak = [Float](repeating: 0.02, count: 1000)   // rms 0.02
        let (out, db) = AudioGain.normalize(weak, targetRMS: 0.1, maxGainDB: 18)
        XCTAssertEqual(rms(out), 0.1, accuracy: 0.005)
        XCTAssertEqual(db, 20 * log10(5), accuracy: 0.1)   // 0.1/0.02 = 5x ≈ 13.98 dB
    }

    func testDoesNotBoostAlreadyHealthyAudio() {
        let healthy = [Float](repeating: 0.15, count: 1000)  // rms 0.15 > target 0.1
        let (out, db) = AudioGain.normalize(healthy, targetRMS: 0.1, maxGainDB: 18)
        XCTAssertEqual(db, 0, accuracy: 0.0001)
        XCTAssertEqual(out, healthy)
    }

    func testCapsGainForVeryQuietAudio() {
        let veryQuiet = [Float](repeating: 0.001, count: 1000)  // desired ~100x
        let (_, db) = AudioGain.normalize(veryQuiet, targetRMS: 0.1, maxGainDB: 18)
        XCTAssertEqual(db, 18, accuracy: 0.001)   // capped, not 40 dB
    }

    func testSilenceIsNoOp() {
        let silence = [Float](repeating: 0, count: 100)
        let (out, db) = AudioGain.normalize(silence)
        XCTAssertEqual(db, 0)
        XCTAssertEqual(out, silence)
    }

    func testEmptyIsNoOp() {
        let (out, db) = AudioGain.normalize([])
        XCTAssertEqual(db, 0)
        XCTAssertTrue(out.isEmpty)
    }

    func testClampsTransientsToUnitRange() {
        var s = [Float](repeating: 0.02, count: 999)
        s.append(0.6)   // a transient that a large boost would push past 1.0
        let (out, _) = AudioGain.normalize(s, targetRMS: 0.1, maxGainDB: 40)
        XCTAssertLessThanOrEqual(out.max() ?? 0, 1.0)
        XCTAssertGreaterThanOrEqual(out.min() ?? 0, -1.0)
    }
}
