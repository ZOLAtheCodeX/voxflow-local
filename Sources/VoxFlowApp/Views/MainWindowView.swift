import SwiftUI

struct MainWindowView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @State private var selectedTab: MainTab = .dashboard

    private enum MainTab: String, CaseIterable, Identifiable {
        case dashboard
        case settings
        case setup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard:
                return "Dashboard"
            case .settings:
                return "Settings"
            case .setup:
                return "Setup"
            }
        }

        var icon: String {
            switch self {
            case .dashboard:
                return "chart.bar.xaxis"
            case .settings:
                return "gearshape"
            case .setup:
                return "wand.and.stars"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardWindowView(coordinator: coordinator, state: state)
                .tabItem { Label(MainTab.dashboard.title, systemImage: MainTab.dashboard.icon) }
                .tag(MainTab.dashboard)

            SettingsView(coordinator: coordinator, state: state)
                .tabItem { Label(MainTab.settings.title, systemImage: MainTab.settings.icon) }
                .tag(MainTab.settings)

            SetupWizardView(coordinator: coordinator, state: state)
                .tabItem { Label(MainTab.setup.title, systemImage: MainTab.setup.icon) }
                .tag(MainTab.setup)
        }
        .onAppear {
            selectDefaultTabIfNeeded()
        }
        .onChange(of: state.onboardingPhase) { _, newPhase in
            if newPhase != .complete {
                selectedTab = .setup
            }
        }
    }

    private func selectDefaultTabIfNeeded() {
        if state.onboardingPhase != .complete {
            selectedTab = .setup
        }
    }
}
