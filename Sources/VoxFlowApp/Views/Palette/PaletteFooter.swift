import SwiftUI

extension CommandPaletteView {
    var footerBar: some View {
        HStack(spacing: VF.spacingSmall) {
            Button {
                onOpenSetup()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .accessibilityLabel("Open Setup Wizard")
            .help("Open Setup Wizard")
            .buttonStyle(.bordered)
            .keyboardShortcut("1", modifiers: [.command])

            Button {
                onOpenDashboardWindow()
            } label: {
                Image(systemName: "chart.bar.xaxis")
            }
            .accessibilityLabel("Open Dashboard")
            .help("Open Dashboard")
            .buttonStyle(.bordered)
            .keyboardShortcut("2", modifiers: [.command])

            SettingsLink {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Open Settings")
            .help("Open Settings")
            .keyboardShortcut(",", modifiers: [.command])

            Spacer()

            polishProviderIndicator

            Button {
                onQuit()
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("Quit VoxFlow")
            .help("Quit VoxFlow")
            .buttonStyle(.bordered)
            .keyboardShortcut("q", modifiers: [.command])
        }
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .padding(.horizontal, 16)
    }

    /// R3.7 mode-in-use indicator: which provider serves polish right now.
    /// Orange = degraded to the local regex fallback (provider chain down).
    /// "rules · local" = the user CHOSE the rules floor (not degraded).
    @ViewBuilder private var polishProviderIndicator: some View {
        let provider = state.backendReadiness.activePolishProvider
        let model = state.backendReadiness.activePolishModel
        let isRules = provider == ProviderConfigStore.rulesSentinel
        if state.backendReadiness.processRunning || !provider.isEmpty {
            HStack(spacing: 3) {
                Image(systemName: provider.isEmpty ? "exclamationmark.triangle" : (isRules ? "text.badge.checkmark" : "brain"))
                    .font(VF.microFont)
                Text(provider.isEmpty ? "regex fallback" : (isRules ? "rules · local" : (model.isEmpty ? provider : "\(provider) · \(model)")))
                    .font(VF.microFont)
                    .lineLimit(1)
            }
            .foregroundStyle(provider.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            .accessibilityLabel(provider.isEmpty
                ? "Polish degraded to regex fallback"
                : (isRules ? "Polish served by local rules (chosen)" : "Polish served by \(provider)"))
            .help(provider.isEmpty
                  ? "No polish provider reachable — output uses the local rules pipeline"
                  : (isRules
                     ? "Local rules only — polish never loads an LLM"
                     : "Polish provider: \(provider) \(model)"))
        }
    }
}
