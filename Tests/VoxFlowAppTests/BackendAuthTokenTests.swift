import XCTest
@testable import VoxFlowApp

final class BackendAuthTokenTests: XCTestCase {
    private var originalToken: String?

    override func setUp() {
        super.setUp()
        originalToken = BackendAuthToken.current()
    }

    override func tearDown() {
        BackendAuthToken.set(originalToken)
        super.tearDown()
    }

    func testGenerateYieldsWellFormedDistinctTokens() {
        var seen = Set<String>()
        for _ in 0..<100 {
            let token = BackendAuthToken.generate()
            XCTAssertTrue(BackendAuthToken.isWellFormed(token), "malformed token generated")
            seen.insert(token)
        }
        XCTAssertEqual(seen.count, 100)
    }

    func testIsWellFormedRejectsMalformedValues() {
        XCTAssertTrue(BackendAuthToken.isWellFormed(String(repeating: "ab", count: 32)))
        XCTAssertFalse(BackendAuthToken.isWellFormed(String(repeating: "AB", count: 32)), "uppercase hex")
        XCTAssertFalse(BackendAuthToken.isWellFormed(String(repeating: "a", count: 63)), "63 chars")
        XCTAssertFalse(BackendAuthToken.isWellFormed(String(repeating: "a", count: 65)), "65 chars")
        XCTAssertFalse(BackendAuthToken.isWellFormed(String(repeating: "ab", count: 32) + "\n"), "trailing newline")
        XCTAssertFalse(BackendAuthToken.isWellFormed(" " + String(repeating: "a", count: 63)), "leading space")
        XCTAssertFalse(BackendAuthToken.isWellFormed(String(repeating: "g", count: 64)), "non-hex")
        XCTAssertFalse(BackendAuthToken.isWellFormed(""))
    }

    func testSetAndCurrentRoundTripAndClear() {
        let token = String(repeating: "cd", count: 32)
        BackendAuthToken.set(token)
        XCTAssertEqual(BackendAuthToken.current(), token)
        BackendAuthToken.set(nil)
        XCTAssertNil(BackendAuthToken.current())
    }

    func testHeaderNameIsPinned() {
        XCTAssertEqual(BackendAuthToken.headerName, "X-VoxFlow-Token")
    }
}
