import SwiftUI

/// Reads one secret by Keychain account. Injected so snapshot and unit tests
/// never touch the real Keychain.
typealias SecretLoader = (String) -> String?

/// The Settings tabs, in display order.
enum SettingsTab: Hashable {
    case general, models, tools, privacy, advanced, permissions
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var snippetStore: SnippetStore
    @ObservedObject var chainStore: ChainStore
    @ObservedObject var providerStore: ProviderConfigStore
    private let secretLoader: SecretLoader
    @State private var selection: SettingsTab

    init(
        coordinator: AppCoordinator,
        state: AppState,
        dictionary: DictionaryStore,
        snippetStore: SnippetStore,
        chainStore: ChainStore,
        providerStore: ProviderConfigStore,
        initialTab: SettingsTab = .general,
        secretLoader: @escaping SecretLoader = { KeychainService.load(account: $0) }
    ) {
        self.coordinator = coordinator
        self.state = state
        self.dictionary = dictionary
        self.snippetStore = snippetStore
        self.chainStore = chainStore
        self.providerStore = providerStore
        self.secretLoader = secretLoader
        _selection = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsPane(coordinator: coordinator, state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ModelsSettingsPane(coordinator: coordinator, state: state, providerStore: providerStore, secretLoader: secretLoader)
                .tabItem { Label("Models", systemImage: "brain") }
                .tag(SettingsTab.models)
            ToolsSettingsPane(coordinator: coordinator, state: state, dictionary: dictionary, snippetStore: snippetStore, chainStore: chainStore, secretLoader: secretLoader)
                .tabItem { Label("Dictation Tools", systemImage: "text.badge.star") }
                .tag(SettingsTab.tools)
            PrivacySettingsPane(coordinator: coordinator, state: state, secretLoader: secretLoader)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.privacy)
            AdvancedSettingsPane(coordinator: coordinator, state: state)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
            PermissionsSettingsPane(coordinator: coordinator)
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }
                .tag(SettingsTab.permissions)
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 560)
    }
}
