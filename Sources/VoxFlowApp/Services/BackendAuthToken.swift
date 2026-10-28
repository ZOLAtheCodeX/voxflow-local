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

    /// The token and, in managed mode, the `instance_stamp` the listener that
    /// holds it must report. Both live in one lock-guarded value so a reader can
    /// never see a token paired with a stale stamp.
    private struct State: Sendable {
        var token: String?
        var expectedStamp: String?
        var rejectionHandler: (@Sendable () -> Void)?
    }

    private static let storage = OSAllocatedUnfairLock<State>(initialState: State())

    static func current() -> String? {
        storage.withLock { $0.token }
    }

    /// The stamp the listener must report before any token-bearing request is
    /// sent (nil in adopt mode and when no token is held: nothing to verify).
    static func expectedStamp() -> String? {
        storage.withLock { $0.expectedStamp }
    }

    /// Publishes the token. Passing no stamp clears any previous one, so a
    /// bare `set(token)` (adopt mode, tests) never inherits a stale stamp.
    /// The rejection handler is independent of the token and is left alone.
    static func set(_ token: String?, expectedStamp: String? = nil) {
        storage.withLock {
            $0.token = token
            $0.expectedStamp = expectedStamp
        }
    }

    /// Registers the reload hook run when a token-bearing request is answered
    /// 401 (adopt mode re-reads the token file). Pass nil to unregister.
    static func setRejectionHandler(_ handler: (@Sendable () -> Void)?) {
        storage.withLock { $0.rejectionHandler = handler }
    }

    /// Called by `BackendAPIClient` on any 401 to a token-bearing request.
    /// The handler runs outside the lock so it may call `set` itself.
    static func tokenRejected() {
        let handler = storage.withLock { $0.rejectionHandler }
        handler?()
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
