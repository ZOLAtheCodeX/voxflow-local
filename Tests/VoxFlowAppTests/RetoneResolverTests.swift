import XCTest
@testable import VoxFlowApp

/// `RetoneResolver` owns the review-mode tone-change decision: try the backend
/// when it's warm, degrade to the in-app `TextCleanupService` on a genuine
/// failure, and propagate cancellation so a superseded retone aborts instead of
/// applying stale tone.
@MainActor
final class RetoneResolverTests: XCTestCase {

    func testUsesBackendOutputWhenBackendSucceeds() async throws {
        let result = try await RetoneResolver.resolve(
            rawText: "hello world", tone: .formal, useBackend: true
        ) { mode in
            mode == .light ? "backend light" : "backend polish"
        }
        XCTAssertEqual(result.light, "backend light")
        XCTAssertEqual(result.polish, "backend polish")
    }

    func testFallsBackToLocalWhenBackendFails() async throws {
        let result = try await RetoneResolver.resolve(
            rawText: "hello world", tone: .formal, useBackend: true
        ) { _ in
            throw URLError(.timedOut)
        }
        // A genuine backend failure degrades to TextCleanupService — NOT an error.
        XCTAssertEqual(result.light, TextCleanupService.cleanup("hello world", mode: .light, tone: .formal))
        XCTAssertEqual(result.polish, TextCleanupService.cleanup("hello world", mode: .polish, tone: .formal))
    }

    func testRethrowsCancellationErrorAsCancellation() async {
        do {
            _ = try await RetoneResolver.resolve(
                rawText: "x", tone: .neutral, useBackend: true
            ) { _ in throw CancellationError() }
            XCTFail("cancellation must propagate, not fall back")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testRethrowsURLCancellationAsCancellation() async {
        do {
            _ = try await RetoneResolver.resolve(
                rawText: "x", tone: .neutral, useBackend: true
            ) { _ in throw URLError(.cancelled) }
            XCTFail("cancellation must propagate, not fall back")
        } catch is CancellationError {
            // URLError.cancelled is normalized to CancellationError
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    func testSkipsBackendEntirelyWhenUseBackendFalse() async throws {
        var called = false
        let result = try await RetoneResolver.resolve(
            rawText: "hello world", tone: .concise, useBackend: false
        ) { _ in
            called = true
            return "should never be used"
        }
        XCTAssertFalse(called, "backend must not be called when useBackend is false")
        XCTAssertEqual(result.light, TextCleanupService.cleanup("hello world", mode: .light, tone: .concise))
        XCTAssertEqual(result.polish, TextCleanupService.cleanup("hello world", mode: .polish, tone: .concise))
    }
}
