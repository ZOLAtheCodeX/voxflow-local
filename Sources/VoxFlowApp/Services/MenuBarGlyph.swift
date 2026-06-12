import AppKit

/// Which glyph the status item shows. The identity states (idle /
/// recording / transcribing) draw the Waveline mark; rare transient
/// states keep SF Symbols.
enum MenuBarIconState: Equatable {
    case idle
    case recording
    case transcribing
    case symbol(String)
}

/// Draws the Waveline brand mark as a menu-bar template image (R4.5):
/// a decaying waveform resolving into a baseline with a cursor dot —
/// the 22 pt sibling of the app icon. Template rendering lets the
/// system tint it correctly on dark/light menu bars and in both
/// status-item states.
enum MenuBarGlyph {

    /// - Parameter amplitude: 1.0 = full wave (recording pulse peak);
    ///   lower values calm the wave (idle uses 0.75, pulse trough 0.55).
    static func waveline(amplitude: CGFloat, includeDot: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            let midY = rect.midY
            let path = NSBezierPath()
            path.lineWidth = 1.9
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Wave: two oscillations decaying left-to-right, then baseline.
            let waveAmp = 5.5 * amplitude
            path.move(to: NSPoint(x: 2.5, y: midY))
            path.curve(to: NSPoint(x: 6.0, y: midY),
                       controlPoint1: NSPoint(x: 3.6, y: midY + waveAmp * 1.0),
                       controlPoint2: NSPoint(x: 4.9, y: midY + waveAmp * 1.0))
            path.curve(to: NSPoint(x: 9.5, y: midY),
                       controlPoint1: NSPoint(x: 7.1, y: midY - waveAmp * 1.0),
                       controlPoint2: NSPoint(x: 8.4, y: midY - waveAmp * 1.0))
            path.curve(to: NSPoint(x: 12.5, y: midY),
                       controlPoint1: NSPoint(x: 10.5, y: midY + waveAmp * 0.6),
                       controlPoint2: NSPoint(x: 11.5, y: midY + waveAmp * 0.6))
            path.line(to: NSPoint(x: includeDot ? 16.5 : 19.5, y: midY))
            NSColor.black.setStroke()
            path.stroke()

            if includeDot {
                let r: CGFloat = 1.7
                let dot = NSBezierPath(ovalIn: NSRect(x: 19.5 - r, y: midY - r, width: r * 2, height: r * 2))
                NSColor.black.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func image(for state: MenuBarIconState, pulsePhase: Bool = false) -> NSImage? {
        switch state {
        case .idle:
            return waveline(amplitude: 0.75, includeDot: true)
        case .recording:
            return waveline(amplitude: pulsePhase ? 0.55 : 1.0, includeDot: true)
        case .transcribing:
            return waveline(amplitude: 0.4, includeDot: false)
        case .symbol(let name):
            let config = NSImage.SymbolConfiguration(scale: .medium)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "VoxFlow")?
                .withSymbolConfiguration(config) else { return nil }
            image.isTemplate = true
            return image
        }
    }
}
