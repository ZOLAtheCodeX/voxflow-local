import SwiftUI

/// The palette's footer: the cleanup provider on its own line (a model name
/// is too long to share a 430 pt row with four buttons), then Settings
/// (Cmd-,), Dashboard (Cmd-2), Cockpit (opens through the same notification
/// as the Welcome window and the Opt-Cmd-V hotkey) and Quit (Cmd-Q). Setup
/// left the footer; a hidden button keeps Cmd-1.
struct PaletteFooter: View {
    @ObservedObject var state: AppState
    var onOpenDashboard: () -> Void
    var onOpenSetup: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            cleanupLabel
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: VF.spacingSmall) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: [.command])
            .help("Open Settings (\u{2318},)")

            Button(action: onOpenDashboard) {
                Label("Dashboard", systemImage: "chart.bar.xaxis")
            }
            .keyboardShortcut("2", modifiers: [.command])
            .help("Open the Dashboard (\u{2318}2)")

            Button {
                NotificationCenter.default.post(name: .voxflowOpenCockpit, object: nil)
            } label: {
                HStack(spacing: VF.spacingXSmall) {
                    Label("Cockpit", systemImage: "rectangle.and.pencil.and.ellipsis")
                    VFKeycap(keys: "\u{2325}\u{2318}V")
                }
            }
            .help("Open the Cockpit (\u{2325}\u{2318}V)")
            .accessibilityLabel("Open the Cockpit")

            Spacer(minLength: VF.spacingSmall)

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .keyboardShortcut("q", modifiers: [.command])
            .help("Quit VoxFlow (\u{2318}Q)")
            .accessibilityLabel("Quit VoxFlow")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background { setupShortcut }
    }

    /// Cmd-1 opens Setup as before. Setup lives in the ••• menu and the
    /// setup banner now, so this button is invisible and hidden from
    /// VoiceOver; it exists only for the shortcut.
    private var setupShortcut: some View {
        Button("Open Setup", action: onOpenSetup)
            .keyboardShortcut("1", modifiers: [.command])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// Which provider cleans up dictated text right now. Warning tint and a
    /// warning symbol when the chain fell back to the built-in rules without
    /// the user choosing them.
    @ViewBuilder private var cleanupLabel: some View {
        let provider = state.backendReadiness.activePolishProvider
        let model = state.backendReadiness.activePolishModel
        if state.backendReadiness.processRunning || !provider.isEmpty {
            let label = VFCopy.cleanupProviderLabel(provider: provider, model: model)
            let degraded = VFCopy.isCleanupDegraded(provider: provider)
            let isRules = provider == ProviderConfigStore.rulesSentinel
            HStack(spacing: VF.spacingXSmall) {
                Image(systemName: degraded ? "exclamationmark.triangle.fill" : (isRules ? "text.badge.checkmark" : "brain"))
                    .accessibilityHidden(true)
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(VF.captionFont)
            .foregroundStyle(degraded ? AnyShapeStyle(VF.colorWarning) : AnyShapeStyle(.secondary))
            .help(degraded
                  ? "No cleanup provider is reachable, so the built-in local rules clean up the text"
                  : (isRules
                     ? "Local rules only: cleanup never loads a language model"
                     : label))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
        }
    }
}
