import XCTest
@testable import VoxFlowApp

/// R5.4 (experimental): hand the transcript to a user-configured agent CLI.
/// The transcript travels via STDIN — never interpolated into the command
/// line, so dictated text cannot inject shell syntax. Never auto-executes:
/// callers must show the payload preview first (UI contract).
@MainActor
final class AssistantHandoffServiceTests: XCTestCase {

    func testDisabledServiceRefusesToRun() async {
        let service = AssistantHandoffService(isEnabled: { false }, command: { "cat" })
        let result = await service.run(transcript: "hello")
        if case .failure(let error) = result {
            XCTAssertEqual(error, .disabled)
        } else {
            XCTFail("disabled service must refuse")
        }
    }

    func testEmptyCommandFails() async {
        let service = AssistantHandoffService(isEnabled: { true }, command: { "  " })
        let result = await service.run(transcript: "hello")
        if case .failure(let error) = result {
            XCTAssertEqual(error, .notConfigured)
        } else {
            XCTFail("missing command must fail")
        }
    }

    func testRoundTripThroughRealCLI() async {
        // tr reads stdin and writes stdout — proves the stdin contract end to end.
        let service = AssistantHandoffService(isEnabled: { true }, command: { "tr a-z A-Z" })
        let result = await service.run(transcript: "summarize the meeting")
        guard case .success(let output) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "SUMMARIZE THE MEETING")
    }

    func testTranscriptIsNotShellInterpolated() async {
        // A transcript full of shell metacharacters must arrive verbatim on
        // stdin — if it were interpolated, this would execute or error.
        let service = AssistantHandoffService(isEnabled: { true }, command: { "cat" })
        let hostile = "\"; rm -rf /tmp/nope; echo \"$(whoami)"
        let result = await service.run(transcript: hostile)
        guard case .success(let output) = result else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), hostile)
    }

    func testFailingCommandSurfacesError() async {
        let service = AssistantHandoffService(isEnabled: { true }, command: { "false" })
        let result = await service.run(transcript: "x")
        if case .failure(let error) = result, case .commandFailed = error {
            // expected
        } else {
            XCTFail("non-zero exit must surface as commandFailed")
        }
    }

    /// Output capture is bounded — a chatty command can't grow memory without limit.
    func testStdoutIsBoundedToMaxBytes() async {
        let service = AssistantHandoffService(
            isEnabled: { true },
            command: { "yes | head -n 100000" },   // ~200 KB
            timeoutSeconds: 15,
            maxOutputBytes: 4096)
        let result = await service.run(transcript: "ignored")
        guard case .success(let out) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertLessThanOrEqual(out.count, 4096, "stdout capture must be bounded")
        XCTAssertGreaterThan(out.count, 0)
    }

    /// A running handoff can be cancelled by the caller: the child process is
    /// terminated and the result is a quiet .cancelled (not .timedOut).
    func testCancellationTerminatesAndReturnsCancelled() async {
        let service = AssistantHandoffService(
            isEnabled: { true }, command: { "sleep 30" }, timeoutSeconds: 60)
        let task = Task { await service.run(transcript: "x") }
        try? await Task.sleep(nanoseconds: 400_000_000)   // let the process start
        task.cancel()
        let result = await task.value
        guard case .failure(.cancelled) = result else {
            return XCTFail("expected .cancelled, got \(result)")
        }
    }

    /// Timeout escalates: a process that ignores SIGTERM is killed with SIGKILL
    /// so the call still returns promptly instead of hanging.
    func testTimeoutEscalatesToSIGKILL() async {
        let service = AssistantHandoffService(
            isEnabled: { true },
            command: { "trap '' TERM; sleep 30" },   // ignores SIGTERM
            timeoutSeconds: 1)
        let start = Date()
        let result = await service.run(transcript: "x")
        let elapsed = Date().timeIntervalSince(start)
        guard case .failure(.timedOut) = result else {
            return XCTFail("expected .timedOut, got \(result)")
        }
        XCTAssertLessThan(elapsed, 10, "must escalate to SIGKILL, not hang on the SIGTERM-ignoring child")
    }

    /// Pipe-buffer deadlock regression: a command whose stdout exceeds the OS
    /// pipe buffer (~64 KB) must not hang. The old code read stdout only AFTER
    /// the process exited, so a chatty CLI blocked on its write forever and the
    /// service killed it at the timeout. Concurrent draining fixes it.
    func testLargeStdoutDoesNotDeadlock() async {
        let service = AssistantHandoffService(
            isEnabled: { true },
            command: { "yes | head -n 100000" },   // ~200 KB of "y\n"
            timeoutSeconds: 15)
        let result = await service.run(transcript: "ignored")
        guard case .success(let output) = result else {
            return XCTFail("chatty command deadlocked/failed: \(result)")
        }
        XCTAssertGreaterThanOrEqual(output.count, 200_000, "full stdout must drain without deadlock")
    }
}
