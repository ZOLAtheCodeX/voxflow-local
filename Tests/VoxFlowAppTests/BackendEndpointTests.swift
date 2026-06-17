import XCTest
@testable import VoxFlowApp

/// `BackendEndpoint` is the single source of truth for where the backend lives.
/// The API client, the stale-listener port checks, and the spawned process all
/// resolve through it so a custom `VOXFLOW_BACKEND_URL` can't desync them.
final class BackendEndpointTests: XCTestCase {

    func testDefaultsToLoopback8765WhenUnset() {
        let ep = BackendEndpoint.resolved(from: [:])
        XCTAssertEqual(ep.host, "127.0.0.1")
        XCTAssertEqual(ep.port, 8765)
        XCTAssertEqual(ep.url.absoluteString, "http://127.0.0.1:8765")
        XCTAssertTrue(ep.isLoopback)
    }

    func testParsesCustomLoopbackPort() {
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "http://127.0.0.1:9000"])
        XCTAssertEqual(ep.host, "127.0.0.1")
        XCTAssertEqual(ep.port, 9000)
        XCTAssertTrue(ep.isLoopback)
    }

    func testParsesLocalhostAsLoopback() {
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "http://localhost:9100"])
        XCTAssertEqual(ep.host, "localhost")
        XCTAssertEqual(ep.port, 9100)
        XCTAssertTrue(ep.isLoopback)
    }

    func testNonLoopbackHostIsNotLoopback() {
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "http://192.168.1.50:8765"])
        XCTAssertEqual(ep.host, "192.168.1.50")
        XCTAssertEqual(ep.port, 8765)
        XCTAssertFalse(ep.isLoopback)
    }

    func testAllInterfacesBindIsNotLoopback() {
        // 0.0.0.0 binds every interface incl. LAN — must not count as loopback.
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "http://0.0.0.0:8765"])
        XCTAssertFalse(ep.isLoopback)
    }

    func testFallsBackToDefaultOnUnparseableURL() {
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "not a url"])
        XCTAssertEqual(ep.host, "127.0.0.1")
        XCTAssertEqual(ep.port, 8765)
    }

    func testParsesHttpsSchemeAndDefaultsTo443() {
        // Parsing only: https is a valid endpoint (for a manually-run backend),
        // but it is NOT eligible for a managed spawn (no TLS on the child).
        let ep = BackendEndpoint.resolved(from: ["VOXFLOW_BACKEND_URL": "https://example.test"])
        XCTAssertEqual(ep.port, 443)
        XCTAssertEqual(ep.scheme, "https")
        XCTAssertFalse(ep.isManagedSpawnEligible)
    }

    func testManagedSpawnEligibilityRequiresLoopbackHTTP() {
        // The only managed-spawnable shape: plain-HTTP loopback.
        XCTAssertTrue(BackendEndpoint.resolved(from: [:]).isManagedSpawnEligible)
        XCTAssertTrue(BackendEndpoint.resolved(
            from: ["VOXFLOW_BACKEND_URL": "http://127.0.0.1:9000"]).isManagedSpawnEligible)
        // https loopback — refused (no TLS terminator on the spawned child).
        XCTAssertFalse(BackendEndpoint.resolved(
            from: ["VOXFLOW_BACKEND_URL": "https://127.0.0.1:9000"]).isManagedSpawnEligible)
        // non-loopback http — refused (LAN exposure).
        XCTAssertFalse(BackendEndpoint.resolved(
            from: ["VOXFLOW_BACKEND_URL": "http://192.168.1.50:8765"]).isManagedSpawnEligible)
    }
}
