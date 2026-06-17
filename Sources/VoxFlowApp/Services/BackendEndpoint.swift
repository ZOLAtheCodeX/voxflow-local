import Foundation

/// Single source of truth for where the backend lives. Parses
/// `VOXFLOW_BACKEND_URL` into `{url, host, port}`, defaulting to
/// `127.0.0.1:8765`, so the API client (`BackendAPIClient.baseURL`), the
/// stale-listener port checks, and the spawned Python process all agree on the
/// same host/port — a custom URL can no longer desync the client from the
/// backend it actually launches.
struct BackendEndpoint: Equatable {
    let url: URL
    let host: String
    let port: Int

    static let defaultHost = "127.0.0.1"
    static let defaultPort = 8765
    static var defaultURLString: String { "http://\(defaultHost):\(defaultPort)" }

    static func resolved(
        from environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> BackendEndpoint {
        let raw = environment["VOXFLOW_BACKEND_URL"] ?? defaultURLString
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            return BackendEndpoint(
                url: URL(string: defaultURLString)!, host: defaultHost, port: defaultPort)
        }
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return BackendEndpoint(url: url, host: host, port: port)
    }

    /// A managed (app-spawned) backend may bind ONLY a loopback host — never a
    /// LAN address or `0.0.0.0` (all interfaces). A non-loopback URL means
    /// "connect to a backend I run myself" and must go through a manual /
    /// adopt-foreign launch; managed spawn refuses it so the backend never
    /// accidentally listens on a routable interface.
    var isLoopback: Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    /// Lower-cased URL scheme, defaulting to `http`.
    var scheme: String { url.scheme?.lowercased() ?? "http" }

    /// Whether the app may spawn its OWN backend for this endpoint. The managed
    /// spawn launches a plain-HTTP uvicorn on loopback, so it requires both a
    /// loopback host AND an `http` scheme — an `https` URL has no TLS terminator
    /// on the child and would leave the client talking TLS to a plaintext
    /// socket. Anything else is a "run-it-yourself" (manual/adopt-foreign) URL.
    var isManagedSpawnEligible: Bool {
        isLoopback && scheme == "http"
    }
}
