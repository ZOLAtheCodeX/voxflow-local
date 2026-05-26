import XCTest
@testable import VoxFlowApp

final class SmartActionServiceTests: XCTestCase {

    func test_apply_returns_backend_result() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "# Issue\n...\n# Recommendation\n...",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        let result = try await service.apply(.memo, to: "raw transcript")

        XCTAssertEqual(result.actionId, .memo)
        XCTAssertTrue(result.output.contains("# Issue"))
        XCTAssertFalse(result.guardrailTriggered)
    }

    func test_history_records_non_guardrail_transforms() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "polished output",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        _ = try await service.apply(.memo, to: "raw")
        let count = await service.historyCount()
        XCTAssertEqual(count, 1)
    }

    func test_history_skips_guardrail_results() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "regex fallback output",
            guardrailTriggered: true,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        _ = try await service.apply(.memo, to: "raw")
        let count = await service.historyCount()
        XCTAssertEqual(count, 0, "guardrail trips don't go in the undo stack")
    }

    func test_history_skips_unchanged_output() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "raw",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        _ = try await service.apply(.memo, to: "raw")
        let count = await service.historyCount()
        XCTAssertEqual(count, 0, "echo / no-op results don't go in the undo stack")
    }

    func test_popLast_returns_before_text() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "polished",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        _ = try await service.apply(.memo, to: "original")
        let popped = await service.popLast()

        XCTAssertNotNil(popped)
        XCTAssertEqual(popped?.0, .memo)
        XCTAssertEqual(popped?.1, "original")
    }

    func test_popLast_returns_nil_when_empty() async {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "x",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        let popped = await service.popLast()
        XCTAssertNil(popped)
    }

    func test_history_cap_at_20() async throws {
        let stub = StubSmartActionBackend(response: SmartActionResult(
            actionId: .memo,
            output: "polished",
            guardrailTriggered: false,
            error: nil
        ))
        let service = SmartActionService(backend: stub)

        for i in 0..<25 {
            _ = try await service.apply(.memo, to: "raw-\(i)")
        }
        let count = await service.historyCount()
        XCTAssertEqual(count, 20, "history caps at 20 entries")
    }

    func test_backend_error_propagates() async {
        let stub = StubSmartActionBackend(response: nil, error: TestError.boom)
        let service = SmartActionService(backend: stub)

        do {
            _ = try await service.apply(.memo, to: "raw")
            XCTFail("expected throw")
        } catch TestError.boom {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

// MARK: - Helpers

private final class StubSmartActionBackend: SmartActionBackend, @unchecked Sendable {
    private let response: SmartActionResult?
    private let error: Error?

    init(response: SmartActionResult?, error: Error? = nil) {
        self.response = response
        self.error = error
    }

    func performSmartAction(_ action: SmartActionId, transcript: String) async throws -> SmartActionResult {
        if let error { throw error }
        return response!
    }
}

private enum TestError: Error { case boom }
