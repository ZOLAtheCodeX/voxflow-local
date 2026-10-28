import Foundation

/// Source of the backend's API token when the app pairs with a backend it did
/// not launch (explicit adopt mode, `VOXFLOW_ADOPT_FOREIGN_BACKEND=1`).
protocol BackendTokenFileReading {
    /// The token, or nil when the file is missing or its content is malformed.
    func readToken() -> String?
}

/// Reads `<dir>/backend.token`, where `<dir>` is the explicit `directory`,
/// else `$VOXFLOW_TOKEN_DIR`, else `~/Library/Application Support/VoxFlow`.
/// The content is a credential: it is never logged or echoed.
struct BackendTokenFile: BackendTokenFileReading {
    static let fileName = "backend.token"

    private let directory: URL

    init(directory: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let directory {
            self.directory = directory
        } else if let override = environment["VOXFLOW_TOKEN_DIR"], !override.isEmpty {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoxFlow", isDirectory: true)
        }
    }

    func readToken() -> String? {
        let url = directory.appendingPathComponent(Self.fileName)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return BackendAuthToken.isWellFormed(token) ? token : nil
    }
}

/// Result of loading the adopted backend's token at launch or after a rejection.
enum AdoptedTokenOutcome: Equatable {
    case notAdopting
    case loaded
    case missing
}
