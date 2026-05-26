import SwiftUI

/// Action chip row — visible smart actions plus the "all actions" overflow.
///
/// Layer 0 ships the three default chips (memo / MECE / items). Other
/// actions appear via the ⌘K palette and graduate into the chip row after
/// 3 invocations (`CockpitCoordinator` promotion logic).
struct CockpitChipRowView: View {
    @ObservedObject var state: AppState
    let coordinator: CockpitCoordinator
    let onActionTriggered: (SmartActionId) -> Void
    let onShowPalette: () -> Void

    var body: some View {
        HStack(spacing: VF.spacingSmall) {
            ForEach(Array(state.chipMRU.prefix(6).enumerated()), id: \.element) { index, action in
                chip(for: action, shortcut: index + 1)
            }
            Spacer()
            Button(action: onShowPalette) {
                Text("⌘K  all actions")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, VF.spacingMedium)
                    .padding(.vertical, 5)
                    .overlay(
                        Capsule()
                            .strokeBorder(VF.colorNeutral.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
        }
    }

    private func chip(for action: SmartActionId, shortcut: Int) -> some View {
        Button {
            onActionTriggered(action)
        } label: {
            HStack(spacing: 4) {
                Text(action.label).font(VF.captionFont)
                Text("⌘\(shortcut)")
                    .font(VF.monoMicroFont)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, VF.spacingMedium)
            .padding(.vertical, 5)
            .background(VF.cardBackground, in: Capsule())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
    }
}
