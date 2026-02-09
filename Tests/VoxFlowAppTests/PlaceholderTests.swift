import XCTest
@testable import VoxFlowApp

final class PlaceholderTests: XCTestCase {
    func testCleanupModeDisplayNamesUnique() {
        let labels = Set(CleanupMode.allCases.map(\.displayName))
        XCTAssertEqual(labels.count, CleanupMode.allCases.count)
    }
}
