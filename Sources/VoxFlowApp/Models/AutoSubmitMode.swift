import Foundation

enum AutoSubmitMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case voiceActionPrompts
    case ordinaryDictation
    case both

    static let defaultsKey = "voxflow.dictation.autoSubmitMode"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .voiceActionPrompts: "Voice Action Prompts only"
        case .ordinaryDictation: "Ordinary dictation only"
        case .both: "Both"
        }
    }

    func includes(voiceActionPrompt: Bool) -> Bool {
        switch self {
        case .off: false
        case .voiceActionPrompts: voiceActionPrompt
        case .ordinaryDictation: !voiceActionPrompt
        case .both: true
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .off
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
