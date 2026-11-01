import SwiftUI

/// Settings > Privacy: inference routing and the private API configuration.
struct PrivacySettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    let secretLoader: SecretLoader
    @State private var privateAPIBaseURLDraft = ""
    @State private var privateAPIModelDraft = ""
    @State private var privateAPIKeyDraft = ""
    @State private var draftsLoaded = false

    var body: some View {
        Form {
            Section("Provider Mode") {
                Picker(
                    "Inference routing",
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

        }
        .formStyle(.grouped)
        .onAppear {
            guard !draftsLoaded else { return }
            draftsLoaded = true
            privateAPIBaseURLDraft = state.privateAPIBaseURL
            privateAPIModelDraft = state.privateAPIModel
            privateAPIKeyDraft = secretLoader(SettingsCoordinator.keychainPrivateAPIKeyAccount) ?? ""
        }
    }
}
