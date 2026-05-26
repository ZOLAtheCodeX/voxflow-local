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
    // Monospaced timer readout — used for the recording-duration counter
    // in the push-to-talk command palette where the digits jitter without
    // a fixed-width design and a bigger weight.
    static let monoTimerFont = Font.system(size: 30, weight: .semibold, design: .monospaced)

    // MARK: - Semantic colors
    //
    // Using SwiftUI's system colors as the underlying value: they adapt to
    // dark/light mode and accent-color overrides for free. Six different
    // views were defining their own `backendStatusColor` — these tokens
    // replace those inline definitions.
    static let colorSuccess: Color = .green
    static let colorWarning: Color = .orange
    static let colorError: Color = .red
    static let colorNeutral: Color = .secondary

    /// Tinted background derived from a semantic color (used for status
    /// pills / badges where a solid fill would be too loud).
    static func tintedBackground(_ color: Color, opacity: Double = 0.15) -> Color {
        color.opacity(opacity)
    }

    // MARK: - Motion
    static let animationStandard: Animation = .smooth(duration: 0.25)
    /// Pulsing animation for live indicators (recording state, waveform).
    static let animationPulse: Animation = .easeInOut(duration: 0.9).repeatForever(autoreverses: true)

    // MARK: - Corners
    static let cornerSmall: CGFloat = 8
    static let cornerMedium: CGFloat = 10
    static let cornerLarge: CGFloat = 12

    // MARK: - Spacing
    static let spacingSmall: CGFloat = 8
    static let spacingMedium: CGFloat = 12
    static let spacingLarge: CGFloat = 16

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
