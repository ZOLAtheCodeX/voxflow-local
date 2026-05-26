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

    static func parse(_ raw: String) -> VoiceCommand {
        let stripped = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\""))
            .lowercased()
        guard !stripped.isEmpty else { return .none }
        // Single-word rule: anything with internal whitespace is content, not a command.
        guard !stripped.contains(where: { $0.isWhitespace }) else { return .none }
        if let action = actionKeywords[stripped] { return .action(action) }
        if let meta = metaKeywords[stripped] { return meta }
        return .none
    }
}
