import XCTest
@testable import VoxFlowApp

final class TranslationBenchmarkCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (TranslationBenchmarkCoordinator, AppState) {
        let state = AppState()
        // Fake runner: never let a unit test reach the real spawn pipeline.
        let backendManager = BackendProcessManager(runner: BackendProcessRunnerFake())
        let settings = SettingsCoordinator(state: state, backendManager: backendManager)
        let sut = TranslationBenchmarkCoordinator(
            state: state,
            backendManager: backendManager,
            settings: settings
        )
        return (sut, state)
    }

    @MainActor
    func testPercentileMedianAndP95() {
        let (sut, _) = makeSUT()
        let values: [Double] = [100, 200, 300, 400, 500]

        let median = sut.percentile(values, p: 0.5)
        XCTAssertEqual(median, 300.0, accuracy: 0.01)

        let p95 = sut.percentile(values, p: 0.95)
        XCTAssertEqual(p95, 480.0, accuracy: 0.01)
    }

    @MainActor
    func testPercentileEmptyReturnsZero() {
        let (sut, _) = makeSUT()
        XCTAssertEqual(sut.percentile([], p: 0.5), 0)
    }

    @MainActor
    func testPercentileSingleValueReturnsValue() {
        let (sut, _) = makeSUT()
        XCTAssertEqual(sut.percentile([42.0], p: 0.5), 42.0)
        XCTAssertEqual(sut.percentile([42.0], p: 0.95), 42.0)
    }

    @MainActor
    func testBenchmarkSamplesReturnsThree() {
        let (sut, _) = makeSUT()
        let samples = sut.benchmarkSamples()
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { !$0.isEmpty })
    }

    @MainActor
    func testUpdateBenchmarkHistoryAccumulatesStats() {
        let (sut, state) = makeSUT()

        let result1 = TranslationBenchmarkResult(
            profile: .translateGemma4B,
            medianLatencyMs: 100,
            p95LatencyMs: 150,
            runs: 3,
            placeholderDetected: false
        )
        sut.updateBenchmarkHistory(with: [result1])

        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.benchmarkRuns, 1)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.successfulRuns, 1)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.totalMedianLatencyMs, 100)

        let result2 = TranslationBenchmarkResult(
            profile: .translateGemma4B,
            medianLatencyMs: 200,
            p95LatencyMs: 250,
            runs: 3,
            placeholderDetected: false
        )
        sut.updateBenchmarkHistory(with: [result2])

        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.benchmarkRuns, 2)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.successfulRuns, 2)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.translateGemma4B]?.totalMedianLatencyMs, 300)
    }

    @MainActor
    func testUpdateBenchmarkHistoryPlaceholderRun() {
        let (sut, state) = makeSUT()

        let result = TranslationBenchmarkResult(
            profile: .marianFallback,
            medianLatencyMs: 0,
            p95LatencyMs: 0,
            runs: 0,
            placeholderDetected: true
        )
        sut.updateBenchmarkHistory(with: [result])

        XCTAssertEqual(state.benchmarkHistoryByProfile[.marianFallback]?.benchmarkRuns, 1)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.marianFallback]?.placeholderRuns, 1)
        XCTAssertEqual(state.benchmarkHistoryByProfile[.marianFallback]?.successfulRuns, 0)
        XCTAssertNil(state.benchmarkHistoryByProfile[.marianFallback]?.lastMedianLatencyMs)
    }

    @MainActor
    func testApplyFastestSelectsMinMedianProfile() {
        let (sut, state) = makeSUT()

        state.translationBenchmarkResults = [
            TranslationBenchmarkResult(
                profile: .translateGemma4B,
                medianLatencyMs: 500,
                p95LatencyMs: 700,
                runs: 3,
                placeholderDetected: false
            ),
            TranslationBenchmarkResult(
                profile: .marianFallback,
                medianLatencyMs: 100,
                p95LatencyMs: 150,
                runs: 3,
                placeholderDetected: false
            ),
            TranslationBenchmarkResult(
                profile: .translateGemma12B,
                medianLatencyMs: 300,
                p95LatencyMs: 400,
                runs: 3,
                placeholderDetected: false
            ),
        ]

        sut.applyFastestBenchmarkProfile()

        XCTAssertEqual(state.translationProfile, .marianFallback)
    }

    @MainActor
    func testApplyFastestSkipsPlaceholderProfiles() {
        let (sut, state) = makeSUT()

        state.translationBenchmarkResults = [
            TranslationBenchmarkResult(
                profile: .translateGemma4B,
                medianLatencyMs: 50,
                p95LatencyMs: 80,
                runs: 3,
                placeholderDetected: true
            ),
            TranslationBenchmarkResult(
                profile: .marianFallback,
                medianLatencyMs: 200,
                p95LatencyMs: 300,
                runs: 3,
                placeholderDetected: false
            ),
        ]

        sut.applyFastestBenchmarkProfile()

        XCTAssertEqual(state.translationProfile, .marianFallback)
    }
}
