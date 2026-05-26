import SwiftUI

/// Cockpit top bar — recording status pill, model badge, target pill.
struct CockpitTopBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sessionService: LongFormSessionService

    var body: some View {
        HStack(spacing: VF.spacingSmall) {
            recordingPill
            modelPill
            Spacer()
            targetPill
        }
        .font(VF.captionFont)
    }

    @ViewBuilder private var recordingPill: some View {
        switch sessionService.state {
        case .idle:
            pill("● ready", tint: VF.colorNeutral)
        case .recording(let startedAt):
            pill("● recording · \(elapsedString(since: startedAt))", tint: VF.colorError)
        case .reviewing:
            pill("● review", tint: .blue)
        }
    }

    private var modelPill: some View {
        let model = state.backendReadiness.ollamaAvailable ? "gemma4:e4b-mlx" : "regex fallback"
        return pill(model, tint: VF.colorNeutral)
    }

    @ViewBuilder private var targetPill: some View {
        if let target = sessionService.currentSession?.targetApp,
           let name = target.appName {
            HStack(spacing: 4) {
                Text("→").foregroundStyle(.secondary)
                pill(name, tint: .blue)
            }
        } else {
            HStack(spacing: 4) {
                Text("→").foregroundStyle(.secondary)
                pill("focused app", tint: VF.colorNeutral)
            }
        }
    }

    private func pill(_ text: String, tint: Color) -> some View {
        Text(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(VF.cardBackground, in: Capsule())
            .foregroundStyle(tint)
    }

    private func elapsedString(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
