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
}
