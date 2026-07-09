import XCTest
@testable import VoxFlowApp

/// Session 29: a rejected capture's PCM was discarded at the moment of
/// failure, so a 12 s dictation that decoded to zero segments was both
/// unattributable (was the audio gappy? garbled? quiet?) and unrecoverable.
/// The store keeps the newest N rejected captures as WAV files, local-only,
/// so the next failure is a solved case instead of a shrug.
final class RejectedAudioStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-rejected-audio-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makePCM(samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testStoreWritesParseableWAV() throws {
        let store = RejectedAudioStore(directory: tempDir, maxClips: 8, enabled: true)
        let pcm = makePCM(samples: [0, 1000, -1000, 32767, -32768])

        let url = try XCTUnwrap(store.store(pcm: pcm, sampleRate: 16_000, reason: "empty"))

        let wav = try Data(contentsOf: url)
        // RIFF/WAVE header, PCM16 mono 16 kHz
        XCTAssertEqual(String(data: wav[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: wav[12..<16], encoding: .ascii), "fmt ")
        func le32(_ offset: Int) -> UInt32 {
            wav[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func le16(_ offset: Int) -> UInt16 {
            wav[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        }
        XCTAssertEqual(le16(20), 1, "audio format must be PCM")
        XCTAssertEqual(le16(22), 1, "channels must be mono")
        XCTAssertEqual(le32(24), 16_000, "sample rate")
        XCTAssertEqual(le16(34), 16, "bits per sample")
        XCTAssertEqual(String(data: wav[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(le32(40), UInt32(pcm.count), "data chunk size")
        XCTAssertEqual(wav[44...], pcm, "payload must be the capture PCM verbatim")
        // Filename carries the reason so a directory listing reads as a log
        XCTAssertTrue(url.lastPathComponent.contains("empty"))
    }

    func testRingPrunesOldestBeyondMaxClips() throws {
        let store = RejectedAudioStore(directory: tempDir, maxClips: 3, enabled: true)
        let pcm = makePCM(samples: [1, 2, 3])
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        var urls: [URL] = []
        for i in 0..<4 {
            let url = try XCTUnwrap(store.store(
                pcm: pcm, sampleRate: 16_000, reason: "empty",
                at: base.addingTimeInterval(Double(i))))
            urls.append(url)
        }

        let remaining = try FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path),
                       "oldest clip must be pruned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[3].path),
                      "newest clip must survive")
    }

    func testKillSwitchDisablesRetentionEntirely() {
        let store = RejectedAudioStore(directory: tempDir, maxClips: 8, enabled: false)
        let url = store.store(pcm: makePCM(samples: [1]), sampleRate: 16_000, reason: "empty")
        XCTAssertNil(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                       "disabled store must not create its directory")
    }

    func testEnabledFlagReadsKillSwitchFromEnvironment() {
        XCTAssertFalse(RejectedAudioStore.isEnabled(environment: ["VOXFLOW_KEEP_REJECTED_AUDIO": "0"]))
        XCTAssertTrue(RejectedAudioStore.isEnabled(environment: [:]))
        XCTAssertTrue(RejectedAudioStore.isEnabled(environment: ["VOXFLOW_KEEP_REJECTED_AUDIO": "1"]))
    }

    /// Empty PCM (a zero-length capture) has nothing to diagnose — no file.
    func testEmptyPCMIsNotStored() {
        let store = RejectedAudioStore(directory: tempDir, maxClips: 8, enabled: true)
        XCTAssertNil(store.store(pcm: Data(), sampleRate: 16_000, reason: "empty"))
    }
}
