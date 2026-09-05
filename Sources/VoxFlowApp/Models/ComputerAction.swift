import Foundation

enum VoiceActionMode: String, CaseIterable, Identifiable, Sendable {
    case off, customPrompts, computerActions, all
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: "Off"
        case .customPrompts: "Custom prompts only"
        case .computerActions: "Built-in computer actions only"
        case .all: "All"
        }
    }
    var includesCustomPrompts: Bool { self == .customPrompts || self == .all }
    var includesComputerActions: Bool { self == .computerActions || self == .all }
}

struct ComputerAction: Codable, Equatable, Identifiable, Sendable {
    enum Operation: String, Codable, Sendable { case openApplication, shortcut }
    let id: String
    let name: String
    let phrases: [String]
    let operation: Operation
    let argument: String

    static let applications: Set<String> = ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal",
                                          "com.apple.Notes", "com.apple.calculator"]
    static let shortcuts: Set<String> = ["copy", "paste", "selectAll", "undo", "redo", "find", "newTab"]
    var isSupported: Bool {
        (operation == .openApplication ? Self.applications : Self.shortcuts).contains(argument)
    }
    var example: String { "Voxflow, \(phrases.first ?? name.lowercased())" }
}

struct ComputerActionCatalog: Decodable, Sendable {
    let version: Int
    let actions: [ComputerAction]

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        var phrases = Set<String>()
        guard result.version == 1, result.actions.count <= 100,
              Set(result.actions.map(\.id)).count == result.actions.count,
              result.actions.allSatisfy({ action in
                  action.isSupported && !action.id.isEmpty && action.id.count <= 128 &&
                  !action.name.isEmpty && action.name.count <= 128 && (1...20).contains(action.phrases.count) &&
                  action.phrases.allSatisfy { phrase in
                      !phrase.isEmpty && phrase.count <= 128 && phrase == phrase.trimmingCharacters(in: .whitespaces) &&
                      phrase.unicodeScalars.allSatisfy { (97...122).contains($0.value) || $0.value == 32 } &&
                      phrases.insert(phrase).inserted
                  }
              }) else { throw ComputerActionError.invalidRegistry }
        return result
    }

    func resolve(_ utterance: String, enabledIDs: Set<String>) -> ComputerAction? {
        guard let phrase = SpokenSkillRouter.normalizedPhrase(utterance) else { return nil }
        // An explicit name prefix and complete phrase distinguish actions from prose.
        let prefixes = ["voxflow ", "voxflow, ", "voxflow: ", "vox flow ", "vox flow, ", "vox flow: "]
        guard let prefix = prefixes.first(where: phrase.hasPrefix) else { return nil }
        let command = String(phrase.dropFirst(prefix.count))
        return actions.first { enabledIDs.contains($0.id) && $0.phrases.contains(command) }
    }
}

enum ComputerActionError: LocalizedError {
    case invalidRegistry, unavailable, preparationFailed, targetChanged
    var errorDescription: String? {
        switch self {
        case .invalidRegistry: "Computer action definitions are invalid."
        case .unavailable: "Computer actions are unavailable in this installation."
        case .preparationFailed: "The computer action could not be prepared."
        case .targetChanged: "Computer action withheld — the original input is no longer focused."
        }
    }
}

/// Changing action permissions invalidates already captured commands, including
/// those awaiting Python preparation. Enabling a setting cannot authorize old audio.
@MainActor
final class CapturedVoiceActions {
    let mode: VoiceActionMode
    let enabledIDs: Set<String>
    private(set) var revoked = false
    init(mode: VoiceActionMode, enabledIDs: Set<String>) {
        self.mode = mode
        self.enabledIDs = enabledIDs
    }
    func revoke() { revoked = true }
}
