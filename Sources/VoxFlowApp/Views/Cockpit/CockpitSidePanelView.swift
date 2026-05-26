import SwiftUI

/// Cockpit side panel — Target + Recent cards.
///
/// Layer 0 omits the Dictionary card (Layer 1) and the ambient-buffer
/// status (Layer 2). Per-layer content per the cockpit design spec.
struct CockpitSidePanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sessionService: LongFormSessionService

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingLarge) {
            targetSection
            recentSection
            Spacer()
        }
        .padding(VF.spacingMedium)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Target")
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(.blue)
                if let target = sessionService.currentSession?.targetApp,
                   let name = target.appName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(VF.labelFont)
                        Text("append at cursor")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("focused app")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(VF.spacingSmall)
            .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent")
            if state.recentDictations.isEmpty {
                Text("No captures yet")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.recentDictations.prefix(3), id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(entry.rawText.prefix(80)) + (entry.rawText.count > 80 ? "…" : ""))
                            .font(VF.captionFont)
                            .lineLimit(2)
                        Text(entry.timestamp, style: .relative)
                            .font(VF.microFont)
                            .foregroundStyle(.secondary)
                    }
                    .padding(VF.spacingSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(VF.captionEmphasizedFont)
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}
