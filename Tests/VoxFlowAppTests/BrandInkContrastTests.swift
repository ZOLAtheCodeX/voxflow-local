import AppKit
import XCTest
@testable import VoxFlowApp

/// The brand teal is too light to read as text on the light window
/// background, so `VF.brandInkNSColor` darkens it in light appearance.
/// This pins WCAG AA (4.5:1) for both appearances.
final class BrandInkContrastTests: XCTestCase {
    func test_brandInk_reaches_4_5_to_1_on_window_background_light_and_dark() {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ratio = wcagContrast(VF.brandInkNSColor, NSColor.windowBackgroundColor, in: name)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, name.rawValue)
        }
    }

    // MARK: - WCAG 2 helpers

    private func wcagContrast(_ a: NSColor, _ b: NSColor, in name: NSAppearance.Name) -> Double {
        let la = relativeLuminance(a, in: name)
        let lb = relativeLuminance(b, in: name)
        let (hi, lo) = (max(la, lb), min(la, lb))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func relativeLuminance(_ color: NSColor, in name: NSAppearance.Name) -> Double {
        var rgb: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB)!
            rgb = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        func lin(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
    }
}
