import XCTest
@testable import VoxFlowApp

final class SetupProgressTests: XCTestCase {
    func test_setup_progress() {
        let p = SetupProgress(microphone: true, accessibility: false, engine: true, calibration: false)
        XCTAssertEqual(p.doneCount, 2)
        XCTAssertEqual(p.total, 4)
        XCTAssertEqual(p.remainingRequired, 1)
    }

    func test_only_microphone_and_accessibility_are_required() {
        let p = SetupProgress(microphone: true, accessibility: true, engine: false, calibration: false)
        XCTAssertEqual(p.remainingRequired, 0)
        let none = SetupProgress(microphone: false, accessibility: false, engine: true, calibration: true)
        XCTAssertEqual(none.remainingRequired, 2)
    }
}
