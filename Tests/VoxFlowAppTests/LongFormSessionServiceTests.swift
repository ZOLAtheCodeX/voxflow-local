import XCTest
@testable import VoxFlowApp

@MainActor
final class LongFormSessionServiceTests: XCTestCase {

    func test_initial_state_is_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    func test_start_transitions_to_recording_and_creates_session() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        if case .recording = service.state {} else { XCTFail("expected recording state") }
        XCTAssertNotNil(service.currentSession)
        XCTAssertEqual(service.currentSession?.transcript, "")
    }

    func test_stop_after_recording_transitions_to_reviewing() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendChunk("hello world")
        service.stop()
        XCTAssertEqual(service.state, .reviewing)
        XCTAssertEqual(service.currentSession?.transcript, "hello world")
    }

    func test_reset_returns_to_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendChunk("x")
        service.stop()
        service.reset()
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    func test_appendChunk_ignored_when_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.appendChunk("noise")
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    // MARK: - Pause tolerance (Task 7)

    func test_silence_longer_than_4s_inserts_paragraph_break() {
        let clock = TestClock()
        let service = LongFormSessionService(autoSaveDirectory: tempDir(), clock: clock)
        service.start()
        service.appendChunk("first sentence.")
        clock.advance(by: 5.0)
        service.appendChunk("second sentence.")
        XCTAssertEqual(service.currentSession?.transcript, "first sentence.\n\nsecond sentence.")
    }

    func test_silence_under_4s_no_paragraph_break() {
        let clock = TestClock()
        let service = LongFormSessionService(autoSaveDirectory: tempDir(), clock: clock)
        service.start()
        service.appendChunk("first.")
        clock.advance(by: 2.0)
        service.appendChunk(" second.")
        XCTAssertEqual(service.currentSession?.transcript, "first. second.")
    }

    func test_paragraph_break_not_duplicated() {
        let clock = TestClock()
        let service = LongFormSessionService(autoSaveDirectory: tempDir(), clock: clock)
        service.start()
        service.appendChunk("first.")
        clock.advance(by: 6.0)
        service.appendChunk("second.")
        clock.advance(by: 7.0)
        service.appendChunk("third.")
        XCTAssertEqual(service.currentSession?.transcript, "first.\n\nsecond.\n\nthird.")
    }

    // MARK: - Persistence (Task 8)

    func test_stop_saves_session_to_disk() throws {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start()
        service.appendChunk("important content")
        service.stop()
        let id = try XCTUnwrap(service.currentSession?.id)

        let url = dir.appendingPathComponent("\(id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LongFormSession.self, from: data)
        XCTAssertEqual(decoded.transcript, "important content")
    }

    func test_recordAppliedAction_overwrites_transcript_and_appends_history() throws {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendChunk("raw text")
        service.stop()
        let applied = AppliedAction(
            actionId: .memo,
            appliedAt: Date(),
            beforeText: "raw text",
            afterText: "# Issue\n..."
        )
        service.recordAppliedAction(applied)
        XCTAssertEqual(service.currentSession?.transcript, "# Issue\n...")
        XCTAssertEqual(service.currentSession?.appliedActions.count, 1)
    }

    // MARK: - Recovery (Task 9)

    func test_recover_loads_most_recent_session() throws {
        let dir = tempDir()
        let older = LongFormSession(transcript: "old content")
        let newer = LongFormSession(transcript: "new content")
        try persist(older, in: dir, updatedAt: Date(timeIntervalSinceNow: -3600))
        try persist(newer, in: dir, updatedAt: Date())

        let service = LongFormSessionService(autoSaveDirectory: dir)
        let recovered = service.recoverLatestSession()

        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.transcript, "new content")
    }

    func test_recover_returns_nil_when_directory_empty() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        XCTAssertNil(service.recoverLatestSession())
    }

    // MARK: - Helpers

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxflow-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persist(_ session: LongFormSession, in dir: URL, updatedAt: Date) throws {
        var copy = session
        copy.updatedAt = updatedAt
        let url = dir.appendingPathComponent("\(copy.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(copy).write(to: url, options: .atomic)
    }
}

private final class TestClock: SessionClock, @unchecked Sendable {
    private(set) var now: Date = Date(timeIntervalSince1970: 1_000_000)
    func currentTime() -> Date { now }
    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
