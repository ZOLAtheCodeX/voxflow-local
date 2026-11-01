import SwiftUI

/// Action chip row: visible smart actions plus the "All Actions" overflow.
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
                HStack(spacing: VF.spacingXSmall) {
                    Text("All Actions")
                        .font(VF.captionFont)
                    VFKeycap(keys: "⌘K")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, VF.spacingMedium)
                .padding(.vertical, 5)
                .overlay(
                    Capsule()
                        .strokeBorder(VF.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
        }
    }

    private func chip(for action: SmartActionId, shortcut: Int) -> some View {
        chipBody(for: action, shortcut: shortcut)
            .accessibilityLabel("\(action.label) smart action")
            .accessibilityHint("Command \(shortcut)")
    }

    private func chipBody(for action: SmartActionId, shortcut: Int) -> some View {
        Button {
            onActionTriggered(action)
        } label: {
            HStack(spacing: VF.spacingXSmall) {
                Text(state.smartActionInFlight == action ? "\(action.label)…" : action.label)
                    .font(VF.captionFont)
                VFKeycap(keys: "⌘\(shortcut)")
            }
            .padding(.horizontal, VF.spacingMedium)
            .padding(.vertical, 5)
            .background(VF.cardBackground, in: Capsule())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
        // Single-flight (session 32): no duplicate dispatch while a transform
        // runs; the running chip keeps full opacity so the user sees which.
        .disabled(state.smartActionInFlight != nil)
        .opacity(state.smartActionInFlight == nil || state.smartActionInFlight == action ? 1 : 0.5)
    }
}
