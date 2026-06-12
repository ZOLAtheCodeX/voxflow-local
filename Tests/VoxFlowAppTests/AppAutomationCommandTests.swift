import XCTest
@testable import VoxFlowApp

final class AppAutomationCommandTests: XCTestCase {

    func testParsesWindowCommand() throws {
        let command = try AppAutomationCommand(url: XCTUnwrap(URL(string: "voxflow://window/setup")))
        XCTAssertEqual(command, .openWindow(.setup))
    }

    func testParsesCockpitWindowCommand() throws {
        let command = try AppAutomationCommand(url: XCTUnwrap(URL(string: "voxflow://window/cockpit")))
        XCTAssertEqual(command, .openWindow(.cockpit))
    }

    func testParsesWorkflowCommandWithEnableFlag() throws {
        let command = try AppAutomationCommand(
            url: XCTUnwrap(URL(string: "voxflow://workflow/translate?enable=1"))
        )
        XCTAssertEqual(command, .selectWorkflow(.translateEnToDe, enableIfNeeded: true))
    }

    func testParsesBackendRecheckCommand() throws {
        let command = try AppAutomationCommand(url: XCTUnwrap(URL(string: "voxflow://backend/recheck")))
        XCTAssertEqual(command, .backend(.recheck))
    }

    func testRejectsUnknownCommandGroup() {
        XCTAssertThrowsError(try AppAutomationCommand(url: XCTUnwrap(URL(string: "voxflow://foo/bar")))) { error in
            XCTAssertEqual(error.localizedDescription, "Unknown automation command group: foo")
        }
    }

    func testRejectsUnknownWorkflowTarget() {
        XCTAssertThrowsError(
            try AppAutomationCommand(url: XCTUnwrap(URL(string: "voxflow://workflow/unknown-mode")))
        ) { error in
            XCTAssertEqual(error.localizedDescription, "Unknown automation target 'unknown-mode' for workflow")
        }
    }
}
