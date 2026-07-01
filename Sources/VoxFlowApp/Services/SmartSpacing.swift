import Foundation

/// R5.0 — boundary-aware insertion spacing. Successive dictations used to
/// land back-to-back ("test.I've tested"); a space is prepended when the
/// character before the cursor needs one and the insertion starts a word.
enum SmartSpacing {
    private static let noSpaceAfter: Set<Character> = [
        " ", "\t", "\n", "\r", "(", "[", "{", "\"", "'", "“", "‘", "/", "-",
    ]

    static func adjusted(_ text: String, precedingCharacter: Character?) -> String {
        guard let preceding = precedingCharacter else { return text }
        guard !noSpaceAfter.contains(preceding) else { return text }
        guard let first = text.first, first.isLetter || first.isNumber else { return text }
        return " " + text
    }

    /// Outcome of the AX read of the character before the cursor. Collapsing
    /// "cursor at position 0" and "field unreadable" into one nil is what put
    /// stray leading spaces at the start of fresh documents in fully
    /// AX-readable apps: only `.unreadable` may consult the prior-insertion
    /// fallback — `.fieldStart` is an authoritative "no preceding character".
    enum AXPrecedingRead: Equatable {
        /// Read succeeded; this character sits before the cursor.
        case character(Character)
        /// Read succeeded; the cursor is at position 0 (empty or fresh field).
        case fieldStart
        /// AX cannot see the field value (Electron, web areas, terminals).
        case unreadable
    }

    /// What VoxFlow last inserted, for the AX-unreadable fallback below.
    struct PriorInsertion {
        /// pid of the app we inserted into (nil = unknown / unresolvable).
        let targetPid: Int32?
        /// Last character of the text we actually inserted — i.e. the character
        /// now sitting before the cursor for the next insertion.
        let trailingCharacter: Character?
        /// When the insertion happened, for the staleness bound below.
        let recordedAt: Date
    }

    /// How long a prior insertion stays trustworthy. The record describes a
    /// field we cannot observe; the user may have sent the message, cleared
    /// the field, or edited it. User key/mouse events invalidate the record
    /// eagerly (AccessibilityInsertService); this age bound is the backstop
    /// for activity that monitoring cannot see (secure input, no permission).
    static let priorInsertionMaxAge: TimeInterval = 60

    /// Resolve the character before the cursor for a spacing decision.
    ///
    /// Prefers the live AX read — both `.character` and `.fieldStart` are
    /// authoritative answers. AX is unreadable in the apps that can't expose
    /// their field value (Electron, web text areas, terminals) — which are the
    /// same apps that fall back to paste insertion, so spacing used to silently
    /// no-op exactly there and dictations ran together. The fallback uses the
    /// trailing character of our OWN last insertion, but ONLY when it went into
    /// the SAME target (matching pid) and is fresher than
    /// ``priorInsertionMaxAge``: we never invent a boundary for a field we have
    /// no knowledge of. Returns nil when no source is trustworthy so `adjusted`
    /// leaves the text untouched.
    static func effectivePrecedingCharacter(
        axRead: AXPrecedingRead,
        prior: PriorInsertion?,
        currentTargetPid: Int32?,
        now: Date = Date()
    ) -> Character? {
        switch axRead {
        case .character(let preceding):
            return preceding
        case .fieldStart:
            return nil
        case .unreadable:
            guard let prior,
                  let priorPid = prior.targetPid,
                  let currentTargetPid,
                  priorPid == currentTargetPid,
                  now.timeIntervalSince(prior.recordedAt) <= priorInsertionMaxAge else { return nil }
            return prior.trailingCharacter
        }
    }
}
