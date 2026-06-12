import XCTest
@testable import VoxFlowApp

/// R4.5: the menu bar wears the Waveline identity. Idle/recording/
/// transcribing draw the brand glyph (template images so the system
/// handles dark/light menu bars); rare transient states keep SF Symbols.
@MainActor
final class MenuBarGlyphTests: XCTestCase {

    func testWavelineRendersTemplateImageAtMenuBarSize() {
        let image = MenuBarGlyph.waveline(amplitude: 1.0, includeDot: true)
        XCTAssertTrue(image.isTemplate, "menu bar glyphs must be template images")
        XCTAssertEqual(image.size.width, 22)
        XCTAssertEqual(image.size.height, 22)
    }

    func testAmplitudeVariantsProduceDistinctImages() {
        let calm = MenuBarGlyph.waveline(amplitude: 0.6, includeDot: true)
        let loud = MenuBarGlyph.waveline(amplitude: 1.0, includeDot: true)
        XCTAssertNotEqual(calm.tiffRepresentation, loud.tiffRepresentation)
    }

    func testSessionStateMapping() {
        XCTAssertEqual(AppCoordinator.menuBarIconState(for: .idle, commandLane: false), .idle)
        XCTAssertEqual(AppCoordinator.menuBarIconState(for: .recording, commandLane: false), .recording)
        XCTAssertEqual(AppCoordinator.menuBarIconState(for: .transcribing, commandLane: false), .transcribing)
        XCTAssertEqual(AppCoordinator.menuBarIconState(for: .review, commandLane: false), .symbol("checkmark.bubble.fill"))
        XCTAssertEqual(AppCoordinator.menuBarIconState(for: .idle, commandLane: true), .symbol("terminal.fill"))
    }
}
