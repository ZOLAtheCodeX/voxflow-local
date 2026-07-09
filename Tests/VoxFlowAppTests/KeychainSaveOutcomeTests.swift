import Security
import XCTest
@testable import VoxFlowApp

/// Pure classifier tests only — NEVER touch the real keychain from tests.
/// Session 29 review: save() discarded both SecItem statuses, so a keychain
/// ACL failure destroyed the old key, dropped the new one, and the UI still
/// showed the key as configured.
final class KeychainSaveOutcomeTests: XCTestCase {

    func testSuccessfulAddSucceeds() {
        XCTAssertTrue(KeychainService.saveSucceeded(
            deleteStatus: errSecSuccess, addStatus: errSecSuccess))
        XCTAssertTrue(KeychainService.saveSucceeded(
            deleteStatus: errSecItemNotFound, addStatus: errSecSuccess))
    }

    func testFailedAddFails() {
        XCTAssertFalse(KeychainService.saveSucceeded(
            deleteStatus: errSecSuccess, addStatus: errSecAuthFailed))
        XCTAssertFalse(KeychainService.saveSucceeded(
            deleteStatus: errSecSuccess, addStatus: errSecInteractionNotAllowed))
    }

    func testClearWithoutAddSucceedsWhenDeleteWorkedOrNothingExisted() {
        XCTAssertTrue(KeychainService.saveSucceeded(
            deleteStatus: errSecSuccess, addStatus: nil))
        XCTAssertTrue(KeychainService.saveSucceeded(
            deleteStatus: errSecItemNotFound, addStatus: nil))
        XCTAssertFalse(KeychainService.saveSucceeded(
            deleteStatus: errSecAuthFailed, addStatus: nil))
    }
}
