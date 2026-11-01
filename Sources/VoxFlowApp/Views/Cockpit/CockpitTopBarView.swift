import SwiftUI

/// Cockpit top bar: session status badge, Discard, in-flight action, cleanup
/// provider, save-failure warning and the insert target.
struct CockpitTopBarView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sessionService: LongFormSessionService
    var onDiscard: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: VF.spacingSmall) {
            statusBadge
            discardButton
            inFlightChip
            Spacer()
            persistenceWarningChip
            providerChip
            targetChip
        }
        .font(VF.captionFont)
    }

    /// Session 29: auto-save failures were silent, so the user could dictate
    /// for half an hour with the crash-recovery contract void. Visible the
    /// moment two consecutive saves fail; disappears on the next success.
    @ViewBuilder private var persistenceWarningChip: some View {
        if sessionService.persistenceFailing {
            VFChip(text: "Not saving to disk", symbol: "exclamationmark.triangle.fill", tint: VF.colorError)
                .accessibilityLabel("Warning: session auto-save is failing")
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch sessionService.state {
        case .recording(let startedAt):
            // TimelineView drives the tick; without it the elapsed string
            // only refreshed when the parent happened to redraw (R4.6).
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VFStatusBadge(status: .cockpit(sessionService.state), detail: elapsedString(since: startedAt))
            }
        default:
            VFStatusBadge(status: .cockpit(sessionService.state))
        }
    }

    /// v0.1.5: review had no visible way out except ⌘↩ (insert) or the spoken
    /// "cancel", so a cockpit reopened in review looked stuck.
    @ViewBuilder private var discardButton: some View {
        if case .reviewing = sessionService.state, let onDiscard {
            Button("Discard", action: onDiscard)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Leave review without inserting. A copy stays in VoxFlow's sessions folder for 7 days.")
        }
    }

    /// Session 32: smart actions had no visible in-progress state (a 6 s
    /// transform looked like a dead chip). Ticks once a second while running.
    @ViewBuilder private var inFlightChip: some View {
        if let action = state.smartActionInFlight, let startedAt = state.smartActionStartedAt {
            TimelineView(.periodic(from: .now, by: 1.0)) { _ in
                VFChip(
                    text: "\(action.label) \(elapsedString(since: startedAt))",
                    symbol: "ellipsis.circle", tint: VF.colorInfo)
            }
            .accessibilityLabel("\(action.label) smart action in progress")
        }
    }

    private var providerChip: some View {
        // R3.7: provenance from /v1/ready, meaning which provider and model
        // the polish chain would use right now. An empty provider is the
        // built-in rules fallback (degraded, warning tint); "rules" is the
        // user's own choice (neutral).
        let provider = state.backendReadiness.activePolishProvider
        let model = state.backendReadiness.activePolishModel
        let isRules = provider == ProviderConfigStore.rulesSentinel
        let degraded = VFCopy.isCleanupDegraded(provider: provider)
        let label = VFCopy.cleanupProviderLabel(provider: provider, model: model)
        return VFChip(text: label, tint: degraded ? VF.colorWarning : VF.colorNeutral)
            .layoutPriority(-1)
            .accessibilityLabel(degraded
                ? "Cleanup degraded to the built-in rules"
                : (isRules ? "Cleanup served by local rules (chosen)" : label))
    }

    private var targetChip: some View {
        let name = sessionService.currentSession?.targetApp?.appName
        return HStack(spacing: VF.spacingXSmall) {
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VFChip(text: name ?? "Focused app", tint: name == nil ? VF.colorNeutral : VF.colorInfo)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target: \(name ?? "Focused app")")
    }

    private func elapsedString(since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
