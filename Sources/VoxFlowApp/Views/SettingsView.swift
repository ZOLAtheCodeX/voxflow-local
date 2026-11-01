import SwiftUI

/// Reads one secret by Keychain account. Injected so snapshot and unit tests
/// never touch the real Keychain.
typealias SecretLoader = (String) -> String?

/// The Settings tabs, in display order.
enum SettingsTab: Hashable, CaseIterable {
    case general, apps, voice, models, privacy, advanced

    var title: String {
        switch self {
        case .general: return "General"
        case .apps: return "Apps"
        case .voice: return "Voice"
        case .models: return "Models"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .apps: return "app.badge"
        case .voice: return "waveform"
        case .models: return "cpu"
        case .privacy: return "lock.shield"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
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
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                pane(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .frame(minWidth: 620, idealWidth: 660, minHeight: 480, idealHeight: 560)
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsPane(coordinator: coordinator, state: state)
        case .apps:
            AppsSettingsPane(coordinator: coordinator, state: state)
        case .voice:
            VoiceSettingsPane(coordinator: coordinator, dictionary: dictionary, snippetStore: snippetStore, chainStore: chainStore)
        case .models:
            ModelsSettingsPane(coordinator: coordinator, state: state, providerStore: providerStore, secretLoader: secretLoader)
        case .privacy:
            PrivacySettingsPane(coordinator: coordinator, state: state, secretLoader: secretLoader)
        case .advanced:
            AdvancedSettingsPane(coordinator: coordinator, state: state, secretLoader: secretLoader)
        }
    }
}
