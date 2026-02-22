import AppKit
import SwiftUI

@main
struct VoxFlowLocalApp: App {
    @ObservedObject var coordinator = AppCoordinator.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedMainWindowOnLaunch = false

    var body: some Scene {
        WindowGroup("VoxFlow", id: "main") {
            MainWindowView(coordinator: coordinator, state: coordinator.state)
                .frame(minWidth: 900, minHeight: 680)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                coordinator.appDidBecomeActive()
            }
        }
        .commands {
            CommandMenu("VoxFlow") {
                Button("Show Main Window") {
                    coordinator.showMainWindow()
                }
                .keyboardShortcut("0", modifiers: [.command])

                Divider()

                Button("Open Dashboard Window") {
                    activateAndOpenWindow(id: "dashboard")
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("Open Setup Wizard") {
                    activateAndOpenWindow(id: "setup")
                }
                .keyboardShortcut("1", modifiers: [.command])
            }
        }

        MenuBarExtra {
            CommandPaletteView(
                coordinator: coordinator,
                state: coordinator.state
            ) {
                activateAndOpenWindow(id: "dashboard")
            } onOpenSetup: {
                activateAndOpenWindow(id: "setup")
            } onQuit: {
                NSApp.terminate(nil)
            }
            .frame(width: 430)
        } label: {
            Image(systemName: iconName(for: coordinator.state))
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel("VoxFlow")
                .help("VoxFlow")
                .onAppear {
                    if !openedMainWindowOnLaunch {
                        openedMainWindowOnLaunch = true
                        coordinator.showMainWindow()
                    }
                }
        }
        .menuBarExtraStyle(.window)

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

    private func activateAndOpenWindow(id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
