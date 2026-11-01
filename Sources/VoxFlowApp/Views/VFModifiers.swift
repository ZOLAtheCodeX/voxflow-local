import SwiftUI

/// Motion and surface wrappers. This is the only view file allowed to use
/// repeating animation (`VF.animationPulse`); every other view reaches live
/// motion through `vfLive`, which honors Reduce Motion.
enum VFMotion {
    /// Repeating motion runs only while something is live and the user has
    /// not asked for reduced motion.
    static func allowsRepeatingAnimation(isActive: Bool, reduceMotion: Bool) -> Bool {
        isActive && !reduceMotion
    }
}

extension EnvironmentValues {
    /// Makes `vfSurface(.hud, in:)` use the `.regularMaterial` look even on
    /// macOS 26, where it would otherwise use Liquid Glass. Nothing in the app
    /// sets it, so live behavior is unchanged; it exists so offscreen renders
    /// (the UI snapshot harness), where glass does not draw, can show the
    /// macOS 14 and 15 look.
    @Entry var vfPrefersMaterialSurfaces: Bool = false
}

enum VFSurfaceKind {
    /// Floating chrome: the pill and the palette panel.
    case hud
    /// Inset card inside a window.
    case card
    /// Editable or readable text area.
    case content
    /// Raised surface above a card.
    case elevated
}

extension AnyTransition {
    /// A state-change transition: a fade under Reduce Motion, otherwise the
    /// fade plus slide the palette uses today.
    static func vfStateChange(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing))
    }
}

extension View {
    /// Pulses opacity while `isActive`, unless Reduce Motion is on, in which
    /// case the view is drawn static.
    func vfLive(_ isActive: Bool) -> some View {
        modifier(VFLiveModifier(isActive: isActive))
    }

    func vfSurface<S: InsettableShape>(_ kind: VFSurfaceKind, in shape: S) -> some View {
        modifier(VFSurfaceModifier(kind: kind, shape: shape))
    }
}

private struct VFLiveModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    private var animates: Bool {
        VFMotion.allowsRepeatingAnimation(isActive: isActive, reduceMotion: reduceMotion)
    }

    func body(content: Content) -> some View {
        content
            .opacity(animates && dimmed ? 0.35 : 1)
            .animation(animates ? VF.animationPulse : .none, value: dimmed)
            .onAppear { restart() }
            .onChange(of: animates) { _, _ in restart() }
    }

    private func restart() {
        // Flipping the flag starts the repeating animation; clearing it while
        // the animation modifier is `.none` ends the pulse and restores full opacity.
        dimmed = animates
    }
}

private struct VFSurfaceModifier<S: InsettableShape>: ViewModifier {
    let kind: VFSurfaceKind
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.vfPrefersMaterialSurfaces) private var prefersMaterial

    private var wantsStroke: Bool {
        contrast == .increased && (kind == .hud || kind == .card)
    }

    func body(content: Content) -> some View {
        surfaced(content)
            .overlay {
                if wantsStroke {
                    shape.strokeBorder(VF.hairline, lineWidth: 1)
                }
            }
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        switch kind {
        case .hud:
            if #available(macOS 26, *), !prefersMaterial {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        case .card:
            content.background(VF.cardBackground, in: shape)
        case .content:
            content.background(VF.surfaceText, in: shape)
        case .elevated:
            content.background(VF.elevatedBackground, in: shape)
        }
    }
}
