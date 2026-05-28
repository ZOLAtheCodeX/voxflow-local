import Foundation

/// Parsed voice command — what the user said during the review state.
enum VoiceCommand: Equatable, Sendable {
    case none
    case action(SmartActionId)
    case undo
    case cancel
    case insert
    case copy
}

/// Single-keyword voice-command parser for the Cockpit review state.
///
/// The grammar is intentionally minimal: one word triggers one command.
/// Multi-word inputs (which are far more likely to be the user dictating
/// content) return ``.none`` rather than partial-matching. Common boundary
/// punctuation (".", "!", "?", ",", ";", ":") is stripped before lookup.
///
/// Voice commands are only meaningful while the long-form session is in
/// the reviewing state — `CockpitCoordinator.handleVoiceUtterance` enforces
/// that gate.
enum VoiceCommandRouter {
    private static let actionKeywords: [String: SmartActionId] = [
        "memo": .memo,
        "mece": .mece,
        "items": .items,
        "steel": .steel,
        "pyramid": .pyramid,
        "disclaimer": .disclaimer,
    ]

    private static let metaKeywords: [String: VoiceCommand] = [
        "undo": .undo,
        "cancel": .cancel,
        "insert": .insert,
        "copy": .copy,
    ]

    /// Trims whitespace/newlines, strips boundary punctuation, lowercases, and enforces the
    /// single-word rule. Returns nil for empty or multi-word input. Shared by ``parse(_:)``
    /// and ``resolveSnippet(_:snippets:context:)`` so their normalization stays identical.
    ///
    /// This is the single source of truth for normalization across both command parsing and
    /// snippet keywords — `SnippetStore.normalizedKeyword(_:)` delegates here so a stored
    /// keyword strips the same boundary punctuation the router strips from speech.
    static func normalizedWord(_ raw: String) -> String? {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\""))
            .lowercased()
        guard !stripped.isEmpty else { return nil }
        // Single-word rule: anything with internal whitespace is content, not a command.
        guard !stripped.contains(where: { $0.isWhitespace }) else { return nil }
        return stripped
    }

    static func parse(_ raw: String) -> VoiceCommand {
        guard let stripped = normalizedWord(raw) else { return .none }
        if let action = actionKeywords[stripped] { return .action(action) }
        if let meta = metaKeywords[stripped] { return meta }
        return .none
    }

    /// Resolves a spoken word to a snippet expansion with scope gating.
    ///
    /// Precedence: reserved meta-words and action keywords always win — if ``parse(_:)``
    /// returns anything other than `.none`, no snippet resolves (returns nil). `context` is
    /// the current surface (callers pass `.longFormOnly` for the cockpit or `.quickOnly`).
    /// A snippet is eligible when its scope is `.global` or equals `context`.
    ///
    /// Callers must pass a concrete surface (`.longFormOnly` or `.quickOnly`), never `.global`,
    /// as the `context` — passing `.global` would make `.longFormOnly`/`.quickOnly` snippets
    /// unreachable. Called by the cockpit review loop (context `.longFormOnly`) and the
    /// quick-dictation path (context `.quickOnly`).
    static func resolveSnippet(_ raw: String, snippets: [VoiceSnippet], context: SnippetScope) -> VoiceSnippet? {
        // Reserved/action words always win over snippets.
        guard parse(raw) == .none else { return nil }
        guard let word = normalizedWord(raw) else { return nil }
        return snippets.first { snippet in
            guard snippet.scope == .global || snippet.scope == context else { return false }
            return SnippetStore.normalizedKeyword(snippet.keyword) == word
        }
    }
}
