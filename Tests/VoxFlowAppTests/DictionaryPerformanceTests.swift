import XCTest
@testable import VoxFlowApp

/// Reproducible opt-in measurement, not a timing assertion on a shared machine.
@MainActor
final class DictionaryPerformanceTests: XCTestCase {
    func testRepeatedCorrections() throws {
        guard ProcessInfo.processInfo.environment["VOXFLOW_DICTIONARY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set VOXFLOW_DICTIONARY_BENCHMARK=1 for the dictionary workload")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for count in [0, 100, 1000] {
            let entries = (0..<count).map {
                DictionaryEntry(wrong: "term\($0)", right: "Preferred\($0)", context: nil,
                                learnedAt: Date(timeIntervalSince1970: 0))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let file = directory.appendingPathComponent("dictionary.json")
            try encoder.encode(entries).write(to: file)
            let store = DictionaryStore(fileURL: file, seedOnFirstRun: false)
            let input = String(repeating: "We reviewed term0 and term99 alongside term999 in the meeting. ", count: 8)
            _ = store.apply(to: input) // exclude the first use from warm measurements
            var timings: [Double] = []
            for _ in 0..<30 {
                let start = ContinuousClock.now
                let output = store.apply(to: input)
                let duration = start.duration(to: .now).components
                timings.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                XCTAssertTrue(output.contains(count == 0 ? "term0" : "Preferred0"))
                XCTAssertTrue(output.contains(count < 1000 ? "term999" : "Preferred999"))
            }
            let sorted = timings.sorted()
            let row: [String: Any] = [
                "benchmark": "dictionary", "entries": count, "samples": sorted.count,
                "median_ms": sorted[sorted.count / 2], "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
                "label": ProcessInfo.processInfo.environment["VOXFLOW_BENCHMARK_LABEL"] ?? "unspecified"
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), as: UTF8.self))
        }
    }
}
