import Foundation
import os
import Security

/// Process-wide holder for the per-launch backend API token.
///
/// `BackendAPIClient` is a namespace of nonisolated statics, so the token lives
/// behind an unfair lock rather than on an actor. Every member is safe to call
/// from any thread. The token is a credential: never log it.
enum BackendAuthToken {
    /// Request header the backend's trust-boundary middleware checks.
    static let headerName = "X-VoxFlow-Token"

    private static let storage = OSAllocatedUnfairLock<String?>(initialState: nil)

    static func current() -> String? {
        storage.withLock { $0 }
    }

    static func set(_ token: String?) {
        storage.withLock { $0 = token }
    }

    /// 32 random bytes from the system CSPRNG as 64 lowercase hex characters.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Exactly 64 lowercase hex characters, no surrounding whitespace.
    static func isWellFormed(_ token: String) -> Bool {
        let utf8 = token.utf8
        guard utf8.count == 64 else { return false }
        return utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
