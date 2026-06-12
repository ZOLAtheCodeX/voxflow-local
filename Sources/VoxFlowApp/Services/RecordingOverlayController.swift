import AppKit
import SwiftUI

/// R4.1 — the floating recording pill.
///
/// During capture the user's eyes are on the TARGET app, not the menu bar
/// panel; before this overlay there was zero on-screen feedback while
/// dictating beyond a swapped status-bar symbol. A small non-activating
/// panel floats top-center showing the live waveform, elapsed time, and
/// the frozen target app; during `.transcribing` it switches to a progress
/// affordance. It never takes key focus, so typing/dictation focus in the
/// target app is untouched.
@MainActor
final class RecordingOverlayController {

    /// Non-activating panel that can never become key — the pill is pure
    /// feedback and must not disturb the frozen capture target.
    private final class PillPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    static let pillSize = NSSize(width: 280, height: 64)

    private let panel: PillPanel
    private let state: AppState

    var isVisible: Bool { panel.isVisible }
    var panelForTesting: NSPanel { panel }

    init(state: AppState, onCancel: @escaping () -> Void) {
        self.state = state
        let panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .utilityWindow

        let content = RecordingPillView(state: state, onCancel: onCancel)
            .frame(width: Self.pillSize.width, height: Self.pillSize.height)
        let hosting = NSHostingView(rootView: content)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
        self.panel = panel
    }

    /// Pure geometry: centered horizontally, 12 pt below the menu bar
    /// (Cocoa coordinates, origin bottom-left).
    nonisolated static func pillOrigin(screenFrame: NSRect, visibleFrame: NSRect, pillSize: NSSize) -> NSPoint {
        let x = screenFrame.midX - pillSize.width / 2
        let y = visibleFrame.maxY - 12 - pillSize.height
        return NSPoint(x: x, y: y)
    }

    func sessionStateChanged(_ newState: SessionState) {
        switch newState {
        case .recording, .transcribing:
            show()
        default:
            hide()
        }
    }

    private func show() {
        guard !panel.isVisible else { return }
        if let screen = NSScreen.main {
            panel.setFrameOrigin(Self.pillOrigin(
                screenFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                pillSize: Self.pillSize
            ))
        }
        panel.orderFrontRegardless()
    }

    private func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
}

/// The pill content: waveform + timer + target while recording; staged
/// progress while transcribing. Visual language matches the Waveline
/// identity — capsule material, monoline waveform, teal accent.
struct RecordingPillView: View {
    @ObservedObject var state: AppState
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: VF.spacingMedium) {
            if state.sessionState == .recording {
                TimelineView(.animation(minimumInterval: 0.08)) { context in
                    HStack(alignment: .center, spacing: 3) {
                        ForEach(0..<7, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.18, green: 0.83, blue: 0.77))
                                .frame(width: 4, height: pillBarHeight(index: index, time: context.date.timeIntervalSinceReferenceDate))
                        }
                    }
                    .frame(width: 52, height: 32)
                }
                .accessibilityLabel("Recording level")

                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.1fs", state.recordingDuration))
                        .font(VF.monoTimerFont)
                    if let appName = state.focusTarget.appName, !appName.isEmpty {
                        Text("→ \(appName)")
                            .font(VF.microFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Recording")
                            .font(VF.microFont)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.sessionState == .recording ? "Cancel recording" : "Cancel transcription")
            .help("Cancel (esc)")
        }
        .padding(.horizontal, VF.spacingMedium)
        .padding(.vertical, VF.spacingSmall)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.sessionState == .recording ? "VoxFlow recording" : "VoxFlow transcribing")
    }

    private func pillBarHeight(index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 5 + Double(index) * 0.9
        let amplitude = (sin(phase) * 0.5 + 0.5) * 0.7 + 0.3
        return CGFloat(8 + amplitude * 22)
    }
}
