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

    /// What VoxFlow last inserted, for the AX-unreadable fallback below.
    struct PriorInsertion {
        /// pid of the app we inserted into (nil = unknown / unresolvable).
        let targetPid: Int32?
        /// Last character of the text we actually inserted — i.e. the character
        /// now sitting before the cursor for the next insertion.
        let trailingCharacter: Character?
    }

    /// Resolve the character before the cursor for a spacing decision.
    ///
    /// Prefers the live AX read. AX returns nil in the apps that can't expose
    /// their field value (Electron, web text areas, terminals) — which are the
    /// same apps that fall back to paste insertion, so spacing used to silently
    /// no-op exactly there and dictations ran together. The fallback uses the
    /// trailing character of our OWN last insertion, but ONLY when it went into
    /// the SAME target (matching pid): we never invent a boundary for a field we
    /// have no knowledge of. Returns nil when neither source is available
    /// (genuine field start, or a different/unknown target) so `adjusted` leaves
    /// the text untouched.
    static func effectivePrecedingCharacter(
        axPreceding: Character?,
        prior: PriorInsertion?,
        currentTargetPid: Int32?
    ) -> Character? {
        if let axPreceding { return axPreceding }
        guard let prior,
              let priorPid = prior.targetPid,
              let currentTargetPid,
              priorPid == currentTargetPid else { return nil }
        return prior.trailingCharacter
    }
}
