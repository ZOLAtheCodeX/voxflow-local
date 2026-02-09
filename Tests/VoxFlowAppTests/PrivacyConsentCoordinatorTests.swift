import XCTest
@testable import VoxFlowApp

final class PrivacyConsentCoordinatorTests: XCTestCase {

    @MainActor
    private func makeSUT() -> (PrivacyConsentCoordinator, AppState) {
        let state = AppState()
        let sut = PrivacyConsentCoordinator(state: state)
        return (sut, state)
    }

    @MainActor
    func testCancelClearsPreviewAndSetsReview() {
        let (sut, state) = makeSUT()
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )
        state.sessionState = .review

        sut.cancelPrivacyPreview()

        XCTAssertNil(state.privacyPreview)
        XCTAssertEqual(state.sessionState, .review)
        XCTAssertEqual(state.statusLine, "Private API request cancelled")
    }

    @MainActor
    func testApproveWithNoPendingIsNoOp() {
        let (sut, state) = makeSUT()
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )

        // No continuation set — approvePrivacyPreview should be a no-op
        sut.approvePrivacyPreview(sendRaw: true)

        // privacyPreview should remain unchanged since no continuation was stored
        XCTAssertNotNil(state.privacyPreview)
        XCTAssertEqual(state.privacyApproveRawCount, 0)
    }

    @MainActor
    func testClearPendingOperationAllowsSubsequentApproveToBeNoOp() {
        let (sut, state) = makeSUT()
        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "tok", originalText: "a", redactedText: "b"
        )

        sut.clearPendingOperation()
        sut.approvePrivacyPreview(sendRaw: false)

        // Should be no-op since continuation was cleared
        XCTAssertEqual(state.privacyApproveRedactedCount, 0)
    }

    @MainActor
    func testApproveRawIncrementsRawCounter() async throws {
        let (sut, state) = makeSUT()
        let expectation = XCTestExpectation(description: "Continuation called")

        state.privacyPreview = PrivacyPreview(
            operation: .cleanup, token: "test-token", originalText: "a", redactedText: "b"
        )

        // Manually set a continuation (simulating what requestPrivacyPreview would do)
        sut.testSetContinuation { token, sendRaw in
            XCTAssertEqual(token, "test-token")
            XCTAssertTrue(sendRaw)
            expectation.fulfill()
        }

        sut.approvePrivacyPreview(sendRaw: true)

        await fulfillment(of: [expectation], timeout: 2.0)

        // Allow the Task inside approvePrivacyPreview to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(state.privacyApproveRawCount, 1)
        XCTAssertEqual(state.privacyApproveRedactedCount, 0)
        XCTAssertNil(state.privacyPreview)
    }

    @MainActor
    func testApproveRedactedIncrementsRedactedCounter() async throws {
        let (sut, state) = makeSUT()
        let expectation = XCTestExpectation(description: "Continuation called")

        state.privacyPreview = PrivacyPreview(
            operation: .translate, token: "red-token", originalText: "a", redactedText: "b"
        )

        sut.testSetContinuation { token, sendRaw in
            XCTAssertEqual(token, "red-token")
            XCTAssertFalse(sendRaw)
            expectation.fulfill()
        }

        sut.approvePrivacyPreview(sendRaw: false)

        await fulfillment(of: [expectation], timeout: 2.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(state.privacyApproveRedactedCount, 1)
        XCTAssertEqual(state.privacyApproveRawCount, 0)
        XCTAssertNil(state.privacyPreview)
    }
}
