import AppKit
import SwiftUI

@main
struct VoxFlowLocalApp: App {
    @StateObject private var coordinator = AppCoordinator.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            CommandPaletteView(coordinator: coordinator, state: coordinator.state) {
                openWindow(id: "dashboard")
            }
                .frame(width: 430)

            Divider()

            Button("Open Setup Wizard") {
                openWindow(id: "setup")
            }
            .keyboardShortcut("w")

            Button("Open Dashboard") {
                openWindow(id: "dashboard")
            }
            .keyboardShortcut("d")

            SettingsLink {
                Text("Settings")
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: iconName(for: coordinator.state))
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel("VoxFlow")
                .help("VoxFlow")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: coordinator, state: coordinator.state)
                .frame(width: 520, height: 420)
        }

        Window("VoxFlow Dashboard", id: "dashboard") {
            DashboardWindowView(coordinator: coordinator, state: coordinator.state)
                .frame(minWidth: 760, minHeight: 540)
        }

        Window("VoxFlow Setup", id: "setup") {
            SetupWizardView(coordinator: coordinator, state: coordinator.state)
                .frame(minWidth: 660, minHeight: 720)
        }
    }

    private func iconName(for state: AppState) -> String {
        if state.isCommandLaneActive {
            return "terminal.fill"
        }

        let sessionState = state.sessionState
        switch sessionState {
        case .idle:
            return "mic.fill"
        case .recording:
            return "record.circle.fill"
        case .transcribing:
            return "waveform"
        case .review:
            return "checkmark.bubble.fill"
        case .inserting:
            return "square.and.arrow.down.fill"
        case .onboarding:
            return "sparkles"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}
