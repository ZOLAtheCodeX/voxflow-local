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
        service.appendTestChunk("hello world")
        service.stop()
        XCTAssertEqual(service.state, .reviewing)
        XCTAssertEqual(service.currentSession?.transcript, "hello world")
    }

    /// Session 29 review: auto-save failures were log-only — the documented
    /// "auto-save every ~5 s" crash-recovery contract could silently void
    /// (disk full, sandbox denial) while the user dictated for 30 minutes
    /// believing the safety net was live. Two consecutive failures publish
    /// `persistenceFailing` so the cockpit can warn.
    func test_repeated_save_failures_publish_persistenceFailing() {
        // A path UNDER a regular file can never be created as a directory,
        // so every save fails deterministically.
        let fileBlocking = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: fileBlocking.path, contents: Data("x".utf8))
        let impossible = fileBlocking.appendingPathComponent("sessions")

        let service = LongFormSessionService(autoSaveDirectory: impossible)
        service.start()
        service.setTranscript("first")   // save #1 fails
        XCTAssertFalse(service.persistenceFailing,
                       "one failure may be transient — no warning yet")
        service.setTranscript("second")  // save #2 fails
        XCTAssertTrue(service.persistenceFailing)

        try? FileManager.default.removeItem(at: fileBlocking)
    }

    func test_successful_save_clears_persistenceFailing() {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start()
        service.setTranscript("hello")
        XCTAssertFalse(service.persistenceFailing)
    }

    func test_reset_returns_to_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("x")
        service.stop()
        service.reset()
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    func test_appendChunk_ignored_when_idle() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.appendChunk("noise", pauseBefore: 0, sessionID: UUID())
        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
    }

    // MARK: - Measured pauses and joining

    func test_first_chunk_becomes_transcript() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("hello", pauseBefore: 5.0)
        XCTAssertEqual(service.currentSession?.transcript, "hello")
    }

    func test_pause_just_under_threshold_joins() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("first.")
        service.appendTestChunk("second.", pauseBefore: 1.9)
        XCTAssertEqual(service.currentSession?.transcript, "first. second.")
    }

    func test_pause_at_threshold_breaks() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("first.")
        service.appendTestChunk("second.", pauseBefore: 2.0)
        XCTAssertEqual(service.currentSession?.transcript, "first.\n\nsecond.")
    }

    func test_break_never_adds_more_than_one_blank_line() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.setTranscript("a\n\n")
        service.appendTestChunk("b", pauseBefore: 3.0)
        XCTAssertEqual(service.currentSession?.transcript, "a\n\nb")
    }

    /// A transcript the user cleared to whitespace is empty: the next chunk
    /// replaces it instead of following a leading blank paragraph.
    func test_whitespace_only_transcript_is_treated_as_empty() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.setTranscript(" \n\n")
        service.appendTestChunk("hello", pauseBefore: 3.0)
        XCTAssertEqual(service.currentSession?.transcript, "hello")

        service.setTranscript("  ")
        service.appendTestChunk("again")
        XCTAssertEqual(service.currentSession?.transcript, "again")
    }

    func test_mismatched_session_id_is_ignored() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendChunk("x", pauseBefore: 0, sessionID: UUID())
        XCTAssertEqual(service.currentSession?.transcript, "")
    }

    // MARK: - Interruption marker

    func test_marker_on_empty_transcript() throws {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        let id = try XCTUnwrap(service.currentSession?.id)
        service.appendInterruptionMarker("device", sessionID: id)
        XCTAssertEqual(service.currentSession?.transcript, "[recording interrupted — device]")
    }

    func test_marker_after_text() throws {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("a")
        let id = try XCTUnwrap(service.currentSession?.id)
        service.appendInterruptionMarker("device", sessionID: id)
        XCTAssertEqual(service.currentSession?.transcript, "a\n\n[recording interrupted — device]")
    }

    func test_marker_after_existing_blank_line_yields_one_blank_line() throws {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.setTranscript("a\n\n")
        let id = try XCTUnwrap(service.currentSession?.id)
        service.appendInterruptionMarker("device", sessionID: id)
        XCTAssertEqual(service.currentSession?.transcript, "a\n\n[recording interrupted — device]")
    }

    func test_marker_with_mismatched_session_id_is_ignored() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.setTranscript("a")
        service.appendInterruptionMarker("device", sessionID: UUID())
        XCTAssertEqual(service.currentSession?.transcript, "a")
    }

    // MARK: - Persistence (Task 8)

    func test_stop_saves_session_to_disk() throws {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start()
        service.appendTestChunk("important content")
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
        service.appendTestChunk("raw text")
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

    // MARK: - Retention (spec 3 decision 5)

    func test_reset_deletes_the_session_file() {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start()
        service.setTranscript("secret")   // setTranscript saves
        let file = dir.appendingPathComponent("\(service.currentSession!.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        service.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test_reset_before_first_save_is_harmless() {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start()
        service.reset()
        XCTAssertEqual(service.state, .idle)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    func test_init_sweeps_only_old_uuid_named_json_files() {
        let dir = tempDir()
        let now = Date()
        let old = dir.appendingPathComponent("\(UUID().uuidString).json")
        let fresh = dir.appendingPathComponent("\(UUID().uuidString).json")
        let foreignJSON = dir.appendingPathComponent("notes.json")
        let foreignOther = dir.appendingPathComponent("\(UUID().uuidString).txt")
        touch(old, modified: now.addingTimeInterval(-8 * 86_400))
        touch(fresh, modified: now.addingTimeInterval(-6 * 86_400))
        [foreignJSON, foreignOther].forEach { touch($0, modified: now.addingTimeInterval(-30 * 86_400)) }

        _ = LongFormSessionService(autoSaveDirectory: dir, clock: FixedClock(now: now))

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignJSON.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreignOther.path))
    }

    func test_orphan_retention_is_seven_days() {
        XCTAssertEqual(LongFormSessionService.orphanRetention, 7 * 24 * 60 * 60)
    }

    // MARK: - Discard (v0.1.5: a visible way out of review)

    /// Before v0.1.5 the only ways out of review were ⌘↩ (insert) and the
    /// spoken "cancel". Discard returns to idle and keeps the session file on
    /// disk, so the transcript stays recoverable.
    func test_discard_in_review_returns_to_idle_and_keeps_the_file() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("hello world")
        service.stop()
        service.setTranscript("hello edited world")

        XCTAssertTrue(service.discard())

        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.currentSession)
        XCTAssertEqual(service.recoverLatestSession()?.transcript, "hello edited world",
                       "discard must leave the latest transcript on disk")
    }

    func test_discarded_session_file_is_swept_after_seven_days() {
        let dir = tempDir()
        let service = LongFormSessionService(autoSaveDirectory: dir)
        service.start(); service.appendTestChunk("discard me"); service.stop()
        let file = dir.appendingPathComponent("\(service.currentSession!.id.uuidString).json")
        XCTAssertTrue(service.discard())
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "discard keeps the file")
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: file.path)
        _ = LongFormSessionService(autoSaveDirectory: dir, clock: FixedClock(now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the sweep removes a discarded file after 7 days")
    }

    /// Discarding mid-recording would leave the microphone running behind an
    /// idle session. Recording ends with ⌘. first.
    func test_discard_is_refused_while_recording() {
        let service = LongFormSessionService(autoSaveDirectory: tempDir())
        service.start()
        service.appendTestChunk("still talking")

        XCTAssertFalse(service.discard())

        if case .recording = service.state {} else { XCTFail("expected recording state") }
        XCTAssertEqual(service.currentSession?.transcript, "still talking")
    }

    // MARK: - Helpers

    private final class FixedClock: SessionClock {
        let now: Date
        init(now: Date) { self.now = now }
        func currentTime() -> Date { now }
    }

    private func touch(_ url: URL, modified: Date) {
        FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8))
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

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
