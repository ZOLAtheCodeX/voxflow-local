import Foundation

@MainActor protocol TranslationBenchmarkCoordinating {
    func runTranslationBenchmark() async
    func applyFastestBenchmarkProfile()
}

@MainActor
final class TranslationBenchmarkCoordinator: TranslationBenchmarkCoordinating {
    private let state: AppState
    private let backendManager: BackendProcessManager
    private let settings: SettingsCoordinating

    init(state: AppState, backendManager: BackendProcessManager, settings: SettingsCoordinating) {
        self.state = state
        self.backendManager = backendManager
        self.settings = settings
    }

    func runTranslationBenchmark() async {
        guard !state.isBenchmarkRunning else { return }

        state.isBenchmarkRunning = true
        state.translationBenchmarkResults = []
        state.benchmarkStatusLine = "Starting translation benchmark..."

        let originalProfile = state.translationProfile
        let samples = benchmarkSamples()
        var results: [TranslationBenchmarkResult] = []

        for (index, profile) in TranslationProfile.allCases.enumerated() {
            state.benchmarkStatusLine = "Benchmarking \(profile.displayName) (\(index + 1)/\(TranslationProfile.allCases.count))"
            backendManager.restart(configuration: settings.backendLaunchConfiguration(for: profile))
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            var latenciesMs: [Double] = []
            var placeholderDetected = false

            for (sampleIndex, sampleText) in samples.enumerated() {
                let started = CFAbsoluteTimeGetCurrent()

                do {
                    let response = try await BackendAPIClient.translate(
                        sessionID: "bench-\(profile.rawValue)-\(sampleIndex)",
                        sourceText: sampleText,
                        sourceLanguage: "en",
                        targetLanguage: "de",
                        providerMode: .localOnly
                    )
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1_000
                    latenciesMs.append(elapsedMs)

                    if response.translatedText.contains("[translation unavailable") {
                        placeholderDetected = true
                    }
                } catch {
                    placeholderDetected = true
                }

                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            let median = percentile(latenciesMs, p: 0.5)
            let p95 = percentile(latenciesMs, p: 0.95)

            results.append(
                TranslationBenchmarkResult(
                    profile: profile,
                    medianLatencyMs: Int(median.rounded()),
                    p95LatencyMs: Int(p95.rounded()),
                    runs: latenciesMs.count,
                    placeholderDetected: placeholderDetected
                )
            )
        }

        state.translationProfile = originalProfile
        backendManager.restart(configuration: settings.currentBackendLaunchConfiguration())

        state.translationBenchmarkResults = results
        updateBenchmarkHistory(with: results)

        let viable = results.filter { !$0.placeholderDetected && $0.runs > 0 }
        if let fastest = viable.min(by: { $0.medianLatencyMs < $1.medianLatencyMs }) {
            if let recommended = state.recommendedProfileFromHistory {
                state.benchmarkStatusLine = "Benchmark complete. Fastest run: \(fastest.profile.displayName). History recommends \(recommended.profile.displayName)."
            } else {
                state.benchmarkStatusLine = "Benchmark complete. Fastest: \(fastest.profile.displayName) (\(fastest.medianLatencyMs) ms median)."
            }
        } else {
            state.benchmarkStatusLine = "Benchmark complete, but profiles returned placeholder output. Download models and retry."
        }

        state.isBenchmarkRunning = false
    }

    func applyFastestBenchmarkProfile() {
        guard !state.isBenchmarkRunning else { return }
        let viable = state.translationBenchmarkResults.filter { !$0.placeholderDetected && $0.runs > 0 }
        if let fastest = viable.min(by: { $0.medianLatencyMs < $1.medianLatencyMs }) {
            settings.selectTranslationProfile(fastest.profile)
            return
        }
        if let recommended = state.recommendedProfileFromHistory {
            settings.selectTranslationProfile(recommended.profile)
        }
    }

    // MARK: - Private Helpers

    func benchmarkSamples() -> [String] {
        [
            "Please send the revised project timeline by tomorrow morning.",
            "I will join the meeting in ten minutes and share the latest status.",
            "Can you summarize the key decisions from today's workshop?"
        ]
    }

    func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(1.0, max(0.0, p))
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        if lowerIndex == upperIndex {
            return sorted[lowerIndex]
        }

        let weight = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1.0 - weight) + sorted[upperIndex] * weight
    }

    func updateBenchmarkHistory(with results: [TranslationBenchmarkResult]) {
        for result in results {
            var stats = state.benchmarkHistoryByProfile[result.profile] ?? TranslationBenchmarkHistoryStats(
                profile: result.profile,
                benchmarkRuns: 0,
                successfulRuns: 0,
                placeholderRuns: 0,
                totalMedianLatencyMs: 0,
                totalP95LatencyMs: 0,
                lastMedianLatencyMs: nil,
                lastP95LatencyMs: nil
            )

            stats.benchmarkRuns += 1
            if result.placeholderDetected || result.runs == 0 {
                stats.placeholderRuns += 1
                stats.lastMedianLatencyMs = nil
                stats.lastP95LatencyMs = nil
            } else {
                stats.successfulRuns += 1
                stats.totalMedianLatencyMs += result.medianLatencyMs
                stats.totalP95LatencyMs += result.p95LatencyMs
                stats.lastMedianLatencyMs = result.medianLatencyMs
                stats.lastP95LatencyMs = result.p95LatencyMs
            }

            state.benchmarkHistoryByProfile[result.profile] = stats
        }
    }
}
