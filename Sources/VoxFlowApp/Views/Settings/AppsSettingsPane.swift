import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Apps: per-app profiles, shown with the app's name and icon.
struct AppsSettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("App profiles") {
                if state.appProfiles.isEmpty {
                    Text("No custom profiles yet. To make one, bring an app to the front, open the VoxFlow panel, and choose its profile from the More options menu.")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.appProfiles.keys.sorted()), id: \.self) { bundleID in
                        if let profile = state.appProfiles[bundleID] {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(nsImage: Self.icon(forBundleID: bundleID))
                                        .resizable()
                                        .frame(width: 20, height: 20)
                                        .accessibilityHidden(true)
                                    Text(Self.displayName(forBundleID: bundleID))
                                        .font(VF.labelFont)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Button("Remove") {
                                        coordinator.updateAppProfile(bundleID: bundleID, profile: nil)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                HStack(spacing: 12) {
                                    pickerColumn("Tone", width: 120) { Picker("Tone", selection: Binding(
                                        get: { profile.tone },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: $0, cleanupMode: profile.cleanupMode, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(ToneStyle.allCases) { t in Text(t.displayName).tag(t) }
                                    }.labelsHidden() }
                                    pickerColumn("Mode", width: 110) { Picker("Mode", selection: Binding(
                                        get: { profile.cleanupMode },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: $0, insertBehavior: profile.insertBehavior)) }
                                    )) {
                                        ForEach(CleanupMode.allCases) { m in Text(m.displayName).tag(m) }
                                    }.labelsHidden() }
                                    pickerColumn("Insert", width: 180) { Picker("Insert", selection: Binding(
                                        get: { profile.insertBehavior },
                                        set: { coordinator.updateAppProfile(bundleID: bundleID, profile: AppProfile(tone: profile.tone, cleanupMode: profile.cleanupMode, insertBehavior: $0)) }
                                    )) {
                                        ForEach(InsertBehavior.allCases) { b in Text(b.displayName).tag(b) }
                                    }.labelsHidden() }
                                }
                                .font(VF.captionFont)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Text("Apps without a profile use the built-in defaults where one exists (for example Slack, Mail, Outlook, Chrome and Xcode), and your General settings everywhere else.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A caption above a picker, so the picker itself keeps its full width and no option is truncated.
    private func pickerColumn<Content: View>(_ label: String, width: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(VF.captionFont).foregroundStyle(.secondary)
            content().frame(width: width, alignment: .leading)
        }
    }

    /// The app's name when its bundle resolves; otherwise the last part of the
    /// bundle ID, so an uninstalled app never shows a full reverse-DNS string.
    private static func displayName(forBundleID bundleID: String) -> String {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            return SkillProfileSettingsSection.applicationName(bundleID)
        }
        return (bundleID.components(separatedBy: ".").last ?? bundleID) + " (not installed)"
    }

    /// The app's own icon when its bundle resolves, a generic application icon otherwise.
    private static func icon(forBundleID bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
