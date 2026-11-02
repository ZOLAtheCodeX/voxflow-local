import XCTest
@testable import VoxFlowApp

/// The transcript editor's draft is bound to the session it was taken from.
/// 2026-11-01 live check: the editor's focus state went stale (it was edited
/// and Discard was pressed while the cockpit was not the key window), so the
/// draft stopped following the session and an old edit replaced the next
/// session's spoken transcript as it entered review.
final class TranscriptDraftTests: XCTestCase {
    private let first = UUID()
    private let second = UUID()

    func test_staleEditFromADiscardedSession_neverCarriesIntoTheNextSession() {
        var draft = TranscriptDraft()
        draft.observe(transcript: "first session", sessionID: first, reviewing: true, editing: false)
        draft.beginEditing()
        draft.edit("an edit that was never committed")

        // Discard, then a whole new recording, while the editor still
        // believes it has focus.
        draft.observe(transcript: nil, sessionID: nil, reviewing: false, editing: true)
        draft.observe(transcript: "", sessionID: second, reviewing: false, editing: true)
        draft.observe(transcript: "spoken words", sessionID: second, reviewing: false, editing: true)
        draft.observe(transcript: "spoken words", sessionID: second, reviewing: true, editing: true)

        XCTAssertEqual(draft.text, "spoken words", "the editor must show the new session's transcript")
        XCTAssertNil(draft.pendingCommit, "the stale focus loss must not write anything")
    }

    func test_editInProgress_survivesObservingTheSameSessionInReview() {
        var draft = TranscriptDraft()
        draft.observe(transcript: "spoken words", sessionID: first, reviewing: true, editing: false)
        draft.beginEditing()
        draft.edit("spoken words, edited")

        draft.observe(transcript: "spoken words", sessionID: first, reviewing: true, editing: true)

        XCTAssertEqual(draft.text, "spoken words, edited")
    }

    func test_pendingCommit_carriesTheSessionTheEditBelongsTo() {
        var draft = TranscriptDraft()
        draft.observe(transcript: "spoken words", sessionID: first, reviewing: true, editing: false)
        draft.beginEditing()
        draft.edit("spoken words, edited")

        XCTAssertEqual(
            draft.pendingCommit,
            TranscriptDraft.Commit(before: "spoken words", after: "spoken words, edited", sessionID: first)
        )
    }

    func test_noCommit_whenTheEditChangedNothing() {
        var draft = TranscriptDraft()
        draft.observe(transcript: "spoken words", sessionID: first, reviewing: true, editing: false)
        draft.beginEditing()

        XCTAssertNil(draft.pendingCommit)
    }
}
