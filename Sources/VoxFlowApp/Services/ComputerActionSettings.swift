import Combine
import Foundation

@MainActor
final class ComputerActionSettings: ObservableObject {
    static let modeKey = "voxflow.voiceActions.mode"
    static let enabledKey = "voxflow.voiceActions.enabledIDs"
    @Published private(set) var mode: VoiceActionMode
    @Published private(set) var enabledIDs: Set<String>
    let catalog: ComputerActionCatalog
    let loadError: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, catalog: ComputerActionCatalog? = nil) {
        self.defaults = defaults
        do {
            self.catalog = try catalog ?? ComputerActionCatalog.decode(Data(contentsOf: ComputerActionResources.registryURL()))
            loadError = nil
        } catch {
            self.catalog = ComputerActionCatalog(version: 1, actions: [])
            loadError = error.localizedDescription
        }
        // Preserve existing custom-profile behavior. New built-ins require opt-in.
        mode = defaults.string(forKey: Self.modeKey).map { VoiceActionMode(rawValue: $0) ?? .off } ?? .customPrompts
        let known = Set(self.catalog.actions.map(\.id))
        if let saved = defaults.array(forKey: Self.enabledKey) as? [String] {
            enabledIDs = Set(saved).intersection(known)
        } else if defaults.object(forKey: Self.enabledKey) != nil {
            enabledIDs = []
        } else {
            enabledIDs = known
            // Pin this version's selection so an update does not enable new actions.
            if !known.isEmpty { defaults.set(known.sorted(), forKey: Self.enabledKey) }
        }
    }

    func setMode(_ mode: VoiceActionMode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
    }
    func setEnabled(_ enabled: Bool, id: String) {
        guard catalog.actions.contains(where: { $0.id == id }) else { return }
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        defaults.set(enabledIDs.sorted(), forKey: Self.enabledKey)
    }
    func snapshot() -> CapturedVoiceActions { CapturedVoiceActions(mode: mode, enabledIDs: enabledIDs) }
}

enum ComputerActionResources {
    static func scriptURL() throws -> URL {
        let fm = FileManager.default
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("backend/app/computer_actions.py"),
                  fm.fileExists(atPath: url.path) else { throw ComputerActionError.unavailable }
            return url
        }
        let root = ProcessInfo.processInfo.environment["VOXFLOW_PROJECT_ROOT"] ?? fm.currentDirectoryPath
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("backend/app/computer_actions.py"),
                          URL(fileURLWithPath: root).appendingPathComponent("backend/app/computer_actions.py")]
        guard let url = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw ComputerActionError.unavailable
        }
        return url
    }
    static func registryURL() throws -> URL { try scriptURL().deletingPathExtension().appendingPathExtension("json") }
    static func pythonURL() throws -> URL {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let root = environment["VOXFLOW_PROJECT_ROOT"] ?? fm.currentDirectoryPath
        let candidates = [environment["VOXFLOW_PYTHON_PATH"].map { URL(fileURLWithPath: $0) },
                          Bundle.main.resourceURL?.appendingPathComponent("venv/bin/python3"),
                          URL(fileURLWithPath: root).appendingPathComponent(".venv/bin/python3"),
                          URL(fileURLWithPath: "/usr/bin/python3")]
        guard let url = candidates.compactMap({ $0 }).first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw ComputerActionError.unavailable
        }
        return url
    }
}
