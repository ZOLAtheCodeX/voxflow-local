import XCTest
@testable import VoxFlowApp

/// Pure-logic coverage for the trust-boundary wiring in AppCoordinator. The
/// coordinator itself is never constructed (it is a singleton that starts
/// warmup); these tests exercise only its nonisolated statics and the token
/// file reader. Nothing here reads the developer's real token file.
final class BackendTrustWiringTests: XCTestCase {
    private var savedToken: String?

    override func setUp() {
        super.setUp()
        savedToken = BackendAuthToken.current()
    }

    override func tearDown() {
        BackendAuthToken.set(savedToken)
        super.tearDown()
    }

    private final class ReaderSpy: BackendTokenFileReading, @unchecked Sendable {
        var calls = 0
        var token: String?
        func readToken() -> String? {
            calls += 1
            return token
        }
    }

    func testNotAdoptingNeverReadsTheTokenFile() {
        BackendAuthToken.set("ab" + String(repeating: "0", count: 62))
        let spy = ReaderSpy()
        XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: false, reader: spy), .notAdopting)
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(BackendAuthToken.current(), "ab" + String(repeating: "0", count: 62))
    }

    func testAdoptLoadsOrClearsToken() {
        let spy = ReaderSpy()
        spy.token = String(repeating: "cd", count: 32)
        XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: true, reader: spy), .loaded)
        XCTAssertEqual(BackendAuthToken.current(), spy.token)
        spy.token = nil
        XCTAssertEqual(AppCoordinator.loadAdoptedBackendToken(explicitAdopt: true, reader: spy), .missing)
        XCTAssertNil(BackendAuthToken.current())
    }

    func testExplicitAdoptIgnoresXCTest() {
        XCTAssertFalse(AppCoordinator.explicitAdoptRequested([:]))
        XCTAssertFalse(AppCoordinator.explicitAdoptRequested(["VOXFLOW_ADOPT_FOREIGN_BACKEND": "true"]))
        XCTAssertTrue(AppCoordinator.explicitAdoptRequested(["VOXFLOW_ADOPT_FOREIGN_BACKEND": "1"]))
    }

    func testTokenFileTrimsWhitespaceAndRejectsMalformed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("backend.token")
        let reader = BackendTokenFile(directory: dir)
        XCTAssertNil(reader.readToken())  // missing
        try (String(repeating: "ab", count: 32) + "\n").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.readToken(), String(repeating: "ab", count: 32))
        try "not-a-token".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(reader.readToken())
    }

    func testTokenFileDirectoryResolvesFromEnvironment() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tok-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let token = String(repeating: "ef", count: 32)
        try token.write(to: dir.appendingPathComponent("backend.token"), atomically: true, encoding: .utf8)
        let reader = BackendTokenFile(environment: ["VOXFLOW_TOKEN_DIR": dir.path])
        XCTAssertEqual(reader.readToken(), token)
    }

    func testTokenRejectionIsRecognizedOnlyFor401() {
        XCTAssertTrue(AppCoordinator.isTokenRejection(BackendError.httpError(statusCode: 401, detail: "Missing or invalid token")))
        XCTAssertFalse(AppCoordinator.isTokenRejection(BackendError.httpError(statusCode: 403, detail: "x")))
        XCTAssertFalse(AppCoordinator.isTokenRejection(URLError(.cannotConnectToHost)))
    }
}
