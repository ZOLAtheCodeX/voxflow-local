import SwiftUI

/// Settings > Privacy: inference routing, the private API configuration, and the
/// microphone and accessibility permissions (with their polling timer).
struct PrivacySettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    let secretLoader: SecretLoader
    @State private var privateAPIBaseURLDraft = ""
    @State private var privateAPIModelDraft = ""
    @State private var privateAPIKeyDraft = ""
    @State private var draftsLoaded = false
    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var permissionPollTimer: Timer?

    var body: some View {
        Form {
            Section("Provider mode") {
                Picker(
                    "Process text with",
                    selection: Binding(
                        get: { state.providerMode },
                        set: { coordinator.selectProviderMode($0) }
                    )
                ) {
                    ForEach(ProviderMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if state.providerMode == .privateAPI {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Private API Base URL", text: $privateAPIBaseURLDraft)
                            .textFieldStyle(.roundedBorder)
                        TextField("Private API Model", text: $privateAPIModelDraft)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Private API Key", text: $privateAPIKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        Button("Apply Private API Config") {
                            coordinator.updatePrivateAPIConfig(
                                baseURL: privateAPIBaseURLDraft,
                                model: privateAPIModelDraft,
                                apiKey: privateAPIKeyDraft
                            )
                        }
                        .buttonStyle(.borderedProminent)

                        Text("Private API calls always require per-request privacy preview and approval.")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    VFStatusBadge(status: Self.permissionStatus(granted: permissions.microphoneAuthorized))
                    Button("Request") {
                        coordinator.requestMicrophonePermission()
                        refreshPermissions()
                    }
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    VFStatusBadge(status: Self.permissionStatus(granted: permissions.accessibilityAuthorized))
                    Button("Request") {
                        coordinator.requestAccessibilityPermission()
                        startPermissionPolling()
                    }
                }

                Button("Refresh Permissions") {
                    refreshPermissions()
                }

                Text("Microphone lets VoxFlow hear you. Accessibility lets it type into other apps.")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .onAppear {
            refreshPermissions()
            guard !draftsLoaded else { return }
            draftsLoaded = true
            privateAPIBaseURLDraft = state.privateAPIBaseURL
            privateAPIModelDraft = state.privateAPIModel
            privateAPIKeyDraft = secretLoader(SettingsCoordinator.keychainPrivateAPIKeyAccount) ?? ""
        }
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    /// The permission vocabulary: Granted is ready, Missing needs attention.
    static func permissionStatus(granted: Bool) -> VFStatus {
        granted ? VFStatus(.ready, "Granted") : VFStatus(.attention, "Missing")
    }

    private func refreshPermissions() {
        permissions = coordinator.permissionSnapshot()
    }

    private func startPermissionPolling() {
        permissionPollTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                let snap = coordinator.permissionSnapshot()
                permissions = snap
                if snap.accessibilityAuthorized {
                    permissionPollTimer?.invalidate()
                    permissionPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionPollTimer = timer
    }
}
