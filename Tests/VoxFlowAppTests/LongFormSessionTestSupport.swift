import Foundation
@testable import VoxFlowApp

extension LongFormSessionService {
    /// Appends to the current session without caring about its id. Does
    /// nothing when no session exists.
    func appendTestChunk(_ text: String, pauseBefore: TimeInterval = 0) {
        guard let id = currentSession?.id else { return }
        appendChunk(text, pauseBefore: pauseBefore, sessionID: id)
    }
}
