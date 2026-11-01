import SwiftUI

/// Reads one secret by Keychain account. Injected so snapshot and unit tests
/// never touch the real Keychain.
typealias SecretLoader = (String) -> String?

/// The Settings tabs, in display order.
enum SettingsTab: Hashable {
    case general, apps, voice, models, privacy, advanced
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
            AppsSettingsPane(coordinator: coordinator, state: state)
                .tabItem { Label("Apps", systemImage: "app.badge") }
                .tag(SettingsTab.apps)
            VoiceSettingsPane(coordinator: coordinator, dictionary: dictionary, snippetStore: snippetStore, chainStore: chainStore)
                .tabItem { Label("Voice", systemImage: "waveform") }
                .tag(SettingsTab.voice)
            ModelsSettingsPane(coordinator: coordinator, state: state, providerStore: providerStore, secretLoader: secretLoader)
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag(SettingsTab.models)
            PrivacySettingsPane(coordinator: coordinator, state: state, secretLoader: secretLoader)
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
                .tag(SettingsTab.privacy)
            AdvancedSettingsPane(coordinator: coordinator, state: state, secretLoader: secretLoader)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.advanced)
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 560)
    }
}
