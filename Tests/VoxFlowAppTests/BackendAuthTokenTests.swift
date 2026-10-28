import XCTest
@testable import VoxFlowApp

final class BackendAuthTokenTests: XCTestCase {
    private var originalToken: String?
    private var originalStamp: String?

    override func setUp() {
        super.setUp()
        originalToken = BackendAuthToken.current()
        originalStamp = BackendAuthToken.expectedStamp()
    }

    override func tearDown() {
        BackendAuthToken.set(originalToken, expectedStamp: originalStamp)
        BackendAuthToken.setRejectionHandler(nil)
        super.tearDown()
    }

    func testSetStoresStampWithTokenAndBareSetClearsIt() {
        BackendAuthToken.set("tok", expectedStamp: "stamp-1")
        XCTAssertEqual(BackendAuthToken.current(), "tok")
        XCTAssertEqual(BackendAuthToken.expectedStamp(), "stamp-1")
        BackendAuthToken.set("tok2")
        XCTAssertEqual(BackendAuthToken.current(), "tok2")
        XCTAssertNil(BackendAuthToken.expectedStamp(), "a bare set must not inherit a stale stamp")
        BackendAuthToken.set("tok3", expectedStamp: "stamp-2")
        BackendAuthToken.set(nil)
        XCTAssertNil(BackendAuthToken.expectedStamp())
    }

    func testTokenRejectedInvokesRegisteredHandlerOnly() {
        BackendAuthToken.tokenRejected()  // no handler: must not crash
        nonisolated(unsafe) var calls = 0
        BackendAuthToken.setRejectionHandler { calls += 1 }
        BackendAuthToken.tokenRejected()
        XCTAssertEqual(calls, 1)
        BackendAuthToken.setRejectionHandler(nil)
        BackendAuthToken.tokenRejected()
        XCTAssertEqual(calls, 1)
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
