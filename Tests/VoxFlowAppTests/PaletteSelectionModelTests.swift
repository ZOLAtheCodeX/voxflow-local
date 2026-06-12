import XCTest
@testable import VoxFlowApp

/// R4.4: keyboard-first ⌘K palette. Selection logic extracted so arrows /
/// return / wrap behavior is unit-testable without a view hierarchy.
final class PaletteSelectionModelTests: XCTestCase {

    func testMoveClampsAndWraps() {
        var model = PaletteSelectionModel(count: 3)
        XCTAssertEqual(model.selectedIndex, 0)
        model.move(1)
        XCTAssertEqual(model.selectedIndex, 1)
        model.move(1); model.move(1)
        XCTAssertEqual(model.selectedIndex, 0, "down past the end wraps to top")
        model.move(-1)
        XCTAssertEqual(model.selectedIndex, 2, "up from the top wraps to bottom")
    }

    func testCountChangeResetsSelectionWhenOutOfRange() {
        var model = PaletteSelectionModel(count: 5)
        model.move(1); model.move(1); model.move(1)
        XCTAssertEqual(model.selectedIndex, 3)
        model.updateCount(2)
        XCTAssertEqual(model.selectedIndex, 0, "filtering resets out-of-range selection")
        model.updateCount(0)
        model.move(1)
        XCTAssertEqual(model.selectedIndex, 0, "empty list never moves")
    }
}
