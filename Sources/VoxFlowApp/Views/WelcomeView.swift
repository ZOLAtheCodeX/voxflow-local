import SwiftUI

/// R4.3 — replaces MainWindowView. The old main window was a TabView
/// duplicating Settings/Dashboard/Setup (including a second, independent
/// SettingsView state island). This is a small launch hub instead: brand
/// mark, live status, and the four doors into the app. The window also
/// hosts the app's notification listeners and automation URL handler via
/// VoxFlowLocalApp, which is why the scene survives the retirement.
struct WelcomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: VF.spacingLarge) {
            VStack(spacing: VF.spacingSmall) {
                WavelineMark()
                    .frame(width: 96, height: 96)
                Text("VoxFlow")
                    .font(VF.titleFont)
                Text("Local-first dictation. Hold Fn to talk; ⌥⌘V for the cockpit.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: VF.spacingMedium) {
                statusChip(
                    label: state.backendReadiness.whisperKitReady || state.backendReadiness.readyForDictation ? "STT ready" : "STT loading",
                    ok: state.backendReadiness.whisperKitReady || state.backendReadiness.readyForDictation
                )
                statusChip(
                    label: state.backendReadiness.activePolishProvider.isEmpty
                        ? "Polish: regex fallback"
                        : "Polish: \(state.backendReadiness.activePolishProvider)",
                    ok: !state.backendReadiness.activePolishProvider.isEmpty
                )
            }

            VStack(spacing: VF.spacingSmall) {
                welcomeButton("Open Setup Wizard", symbol: "wand.and.stars", shortcut: "⌥⌘1") {
                    NotificationCenter.default.post(name: .voxflowOpenSetup, object: nil)
                }
                welcomeButton("Open Dashboard", symbol: "chart.bar.xaxis", shortcut: "⌥⌘2") {
                    NotificationCenter.default.post(name: .voxflowOpenDashboard, object: nil)
                }
                welcomeButton("Open Cockpit", symbol: "rectangle.and.pencil.and.ellipsis", shortcut: "⌥⌘V") {
                    NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)
                }
                SettingsLink {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Settings")
                        Spacer()
                        Text("⌘,").font(VF.monoCaptionFont).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(VF.spacingLarge * 2)
        .frame(minWidth: 420, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusChip(label: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ok ? VF.colorSuccess : VF.colorWarning)
                .frame(width: 7, height: 7)
            Text(label).font(VF.captionFont).foregroundStyle(.secondary)
        }
        .padding(.horizontal, VF.spacingSmall)
        .padding(.vertical, 4)
        .background(VF.cardBackground, in: Capsule())
    }

    private func welcomeButton(_ title: String, symbol: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol)
                Text(title)
                Spacer()
                Text(shortcut).font(VF.monoCaptionFont).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 280)
        }
        .buttonStyle(.bordered)
    }
}

/// The Waveline brand mark as a SwiftUI shape — shared visual language
/// with the app icon and menu bar glyph.
struct WavelineMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.225, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.137, green: 0.149, blue: 0.18), Color(red: 0.078, green: 0.086, blue: 0.106)],
                        startPoint: .top, endPoint: .bottom
                    ))
                Path { path in
                    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                        CGPoint(x: x / 100 * w, y: y / 100 * h)
                    }
                    path.move(to: pt(12, 50))
                    path.addQuadCurve(to: pt(22, 50), control: pt(17, 22))
                    path.addQuadCurve(to: pt(32, 50), control: pt(27, 78))
                    path.addQuadCurve(to: pt(42, 50), control: pt(37, 30))
                    path.addQuadCurve(to: pt(52, 50), control: pt(47, 70))
                    path.addLine(to: pt(76, 50))
                }
                .stroke(Color(red: 0.957, green: 0.949, blue: 0.925), style: StrokeStyle(lineWidth: w * 0.065, lineCap: .round, lineJoin: .round))
                Circle()
                    .fill(Color(red: 0.184, green: 0.831, blue: 0.773))
                    .frame(width: w * 0.096, height: w * 0.096)
                    .position(x: 0.85 * w, y: 0.5 * h)
            }
        }
        .accessibilityLabel("VoxFlow")
    }
}
