import XCTest
@testable import VoxFlowApp

/// Per-buffer ingest step of the audio tap, extracted so the
/// generation-token guard is testable without constructing the real
/// service's AVAudioEngine. The guard exists because `removeTap` does not
/// synchronize with an executing tap block: a stale callback from the
/// PREVIOUS capture could otherwise claim the new capture's first-buffer
/// slot — firing the "speak now" cue before the engine is live, appending
/// old audio, and poisoning `firstBufferLatencyMs` receipts with ~0 values.
final class AudioCaptureIngestTests: XCTestCase {

    private func makeState(generation: UInt64) -> AudioCaptureService.State {
        var state = AudioCaptureService.State()
        state.generation = generation
        state.captureStartedAt = ContinuousClock.now
        return state
    }

    func testFirstBufferAppendsRecordsLatencyAndReturnsLiveCallbackOnce() {
        var state = makeState(generation: 1)
        state.onCaptureLive = {}

        let first = AudioCaptureService.ingest(
            state: &state, chunk: Data([1, 2]), generation: 1)
        XCTAssertNotNil(first, "first buffer must surface the live callback")
        XCTAssertNotNil(state.firstBufferLatencyMs)
        XCTAssertEqual(state.pcmBuffer, Data([1, 2]))

        let second = AudioCaptureService.ingest(
            state: &state, chunk: Data([3]), generation: 1)
        XCTAssertNil(second, "live callback fires once, not per buffer")
        XCTAssertEqual(state.pcmBuffer, Data([1, 2, 3]))
    }

    func testStaleGenerationCallbackIsFullyIgnored() {
        // startCapture bumped the generation to 2; a still-executing tap block
        // from the previous capture arrives carrying generation 1.
        var state = makeState(generation: 2)
        state.onCaptureLive = {}

        let live = AudioCaptureService.ingest(
            state: &state, chunk: Data([9, 9]), generation: 1)

        XCTAssertNil(live, "stale callback must not fire the new capture's cue")
        XCTAssertTrue(state.pcmBuffer.isEmpty, "stale audio must not leak into the new capture")
        XCTAssertNil(state.firstBufferLatencyMs, "stale callback must not poison the latency receipt")
    }

    func testBufferLimitFlagsAndStopsAppending() {
        var state = makeState(generation: 1)
        state.pcmBuffer = Data([0, 0, 0, 0])

        _ = AudioCaptureService.ingest(
            state: &state, chunk: Data([1]), generation: 1, maxBytes: 4)

        XCTAssertTrue(state.bufferLimitReached)
        XCTAssertEqual(state.pcmBuffer.count, 4, "no append past the limit")
    }
}
