import SwiftUI

extension CommandPaletteView {
    func appProfilePopover(bundleID: String, appName: String) -> some View {
        let current = state.appProfiles[bundleID]
            ?? SettingsCoordinator.defaultAppProfiles[bundleID]
            ?? AppProfile(tone: state.toneStyle, cleanupMode: state.selectedMode, insertBehavior: state.insertBehavior)

        return VStack(alignment: .leading, spacing: 10) {
            Text("Profile for \(appName)")
                .font(VF.labelFont.weight(.semibold))

            Picker("Tone", selection: Binding(
                get: { current.tone },
                set: { newTone in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: newTone, cleanupMode: current.cleanupMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
            }

            Picker("Cleanup", selection: Binding(
                get: { current.cleanupMode },
                set: { newMode in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: newMode, insertBehavior: current.insertBehavior))
                }
            )) {
                ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
            }

            Picker("Insert", selection: Binding(
                get: { current.insertBehavior },
                set: { newBehavior in
                    coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: current.tone, cleanupMode: current.cleanupMode, insertBehavior: newBehavior))
                }
            )) {
                ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
            }

            if state.appProfiles[bundleID] != nil {
                Button("Reset to Default") {
                    coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                    showProfilePopover = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
