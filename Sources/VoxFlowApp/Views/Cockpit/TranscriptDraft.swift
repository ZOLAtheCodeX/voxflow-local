import Foundation

/// The cockpit transcript editor's draft and the commit it owes when an edit
/// ends. A pure value type so the sync and commit policy is unit-tested;
/// ``CockpitTranscriptView`` keeps the SwiftUI wiring mechanical.
struct TranscriptDraft: Equatable {
    /// An ended edit's write: the text the edit started from, the edited
    /// text, and the session the edit belongs to.
    struct Commit: Equatable {
        let before: String
        let after: String
        let sessionID: UUID
    }

    private(set) var text = ""
    private(set) var baseline = ""
    private(set) var sessionID: UUID?

    /// The session's transcript, identity or review state changed. The draft
    /// is kept only for an edit in progress on the same session in review;
    /// anything else re-seeds it from the session. Keying on `editing` alone
    /// let a stale focus state carry an old session's edit into the next one.
    mutating func observe(transcript: String?, sessionID: UUID?, reviewing: Bool, editing: Bool) {
        if editing, reviewing, sessionID != nil, sessionID == self.sessionID { return }
        text = transcript ?? ""
        baseline = text
        self.sessionID = sessionID
    }

    /// The editor took focus: the edit starts from what it shows now.
    mutating func beginEditing() {
        baseline = text
    }

    /// The editor's text binding changed.
    mutating func edit(_ newText: String) {
        text = newText
    }

    /// The write an ended edit owes, or nil when nothing changed.
    var pendingCommit: Commit? {
        guard let sessionID, text != baseline else { return nil }
        return Commit(before: baseline, after: text, sessionID: sessionID)
    }
}
