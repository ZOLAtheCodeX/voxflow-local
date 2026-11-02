import AppKit
import SwiftUI

/// Centralised design tokens.
///
/// All views must reference these constants instead of hardcoding sizes,
/// colors, or animations. The whole design system can be re-tuned by
/// editing one file.
///
/// Naming convention:
///   - `*Font`        — typography (size + weight)
///   - `color*`       — semantic colors (success / warning / error / neutral)
///   - `animation*`   — motion presets
///   - `corner*`      — corner radii
///   - `spacing*`     — layout spacing
///   - `background*`  — material / surface styles
enum VF {
    // MARK: - Typography
    //
    // Font tokens are discrete (size, weight) pairs so the call site reads
    // semantically — `.font(VF.captionEmphasizedFont)` instead of
    // `.font(.system(size: 11, weight: .semibold))`.
    static let displayFont = Font.system(size: 22, weight: .bold)
    static let largeFont = Font.system(size: 18, weight: .bold)
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let headingFont = Font.system(size: 14, weight: .semibold)
    static let bodyEmphasizedFont = Font.system(size: 13, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let labelFont = Font.system(size: 12, weight: .medium)
    static let secondaryFont = Font.system(size: 12)
    static let captionEmphasizedFont = Font.system(size: 11, weight: .semibold)
    static let captionFont = Font.system(size: 11)

    // Monospaced caption variants — used for byte counts, latency timings,
    // and Ollama pull-progress lines where digit-alignment matters.
    static let monoCaptionFont = Font.system(size: 11, design: .monospaced)
    static let monoMicroFont = Font.system(size: 10, design: .monospaced)
    static let microFont = Font.system(size: 10)
    /// Recording-duration readout in the push-to-talk palette. Proportional
    /// digits made fixed-width with `monospacedDigit()` so the counter does
    /// not jitter.
    static let timerFont = Font.system(size: 30, weight: .semibold).monospacedDigit()

    // Reading text (transcripts, last-dictation card). Wider line spacing and
    // a capped measure keep long passages comfortable to read.
    static let readingFont = Font.system(size: 15)
    static let readingLineSpacing: CGFloat = 4
    static let readingMaxWidth: CGFloat = 640

    // MARK: - Semantic colors
    //
    // Using SwiftUI's system colors as the underlying value: they adapt to
    // dark/light mode and accent-color overrides for free. Six different
    // views were defining their own `backendStatusColor` — these tokens
    // replace those inline definitions.
    static let colorSuccess: Color = .green
    static let colorWarning: Color = .orange
    static let colorError: Color = .red
    /// Informational accents (R4.6) — replaces raw .blue scattered in views.
    static let colorInfo: Color = .blue
    /// External-service accents (Notion etc.) — replaces raw .orange icons.
    static let colorExternal: Color = .orange
    static let colorNeutral: Color = .secondary

    /// Tinted background derived from a semantic color (used for status
    /// pills / badges where a solid fill would be too loud).
    static func tintedBackground(_ color: Color, opacity: Double = 0.15) -> Color {
        color.opacity(opacity)
    }

    // MARK: - Brand
    //
    // `colorBrand` is the Waveline teal (#2FD4C5). It is a fill and accent
    // color, not a text color on light surfaces: use `colorBrandInk` for
    // text and glyphs that must stay legible in both appearances.
    static let colorBrand = Color(red: 0.184, green: 0.831, blue: 0.773)

    /// Brand teal tuned per appearance: the bright brand teal on dark, a
    /// darker teal (#0A6F68, about 5.1:1 on #ECECEC) on light so it clears
    /// WCAG AA 4.5:1 as text. Pinned by `BrandInkContrastTests`.
    static let brandInkNSColor = NSColor(name: "VoxFlowBrandInk") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0x2F / 255.0, green: 0xD4 / 255.0, blue: 0xC5 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 0x0A / 255.0, green: 0x6F / 255.0, blue: 0x68 / 255.0, alpha: 1)
    }
    static let colorBrandInk = Color(nsColor: brandInkNSColor)
    /// The "listening" state reads as brand ink.
    static let colorListening: Color = colorBrandInk
    /// Voice-control (spoken command) state.
    static let colorVoiceControl: Color = .indigo

    // The three `WavelineMark` colors: plate gradient top and bottom, and the
    // wave stroke.
    static let brandPlateTop = Color(red: 0.137, green: 0.149, blue: 0.18)
    static let brandPlateBottom = Color(red: 0.078, green: 0.086, blue: 0.106)
    static let brandStroke = Color(red: 0.957, green: 0.949, blue: 0.925)

    // MARK: - Surfaces
    static let surfaceWindow = Color(nsColor: .windowBackgroundColor)
    static let surfaceText = Color(nsColor: .textBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)

    // MARK: - Motion
    static let animationStandard: Animation = .smooth(duration: 0.25)
    /// Pulsing animation for live indicators (recording state, waveform).
    static let animationPulse: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    // MARK: - Corners
    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 12

    // MARK: - Spacing
    static let spacingXSmall: CGFloat = 4
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 16
    static let spacingXLarge: CGFloat = 24

    // MARK: - Background materials
    //
    // `cardBackground` is the standard inset-card style used across the
    // Dashboard / Setup / Onboarding flows. It replaces the legacy
    // hardcoded grey-with-opacity card fills with a material that adapts
    // to dark/light mode automatically.
    //
    // `panelMaterial` is `.ultraThinMaterial` and is reserved for the
    // top-level menu-bar NSPanel content view. Per project convention,
    // other views should use `.quaternary` (via `cardBackground`) — only
    // the NSPanel gets translucency.
    static let cardBackground: HierarchicalShapeStyle = .quaternary
    static let elevatedBackground: Material = .regularMaterial
    static let panelMaterial: Material = .ultraThinMaterial
}
