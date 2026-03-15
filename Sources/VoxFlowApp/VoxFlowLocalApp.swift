import AppKit
import SwiftUI

@main
struct VoxFlowLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject var coordinator = AppCoordinator.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("VoxFlow", id: "main") {
            MainWindowView(coordinator: coordinator, state: coordinator.state)
                .frame(minWidth: 900, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: .voxflowOpenDashboard)) { _ in
                    activateAndOpenWindow(id: "dashboard")
                }
                .onReceive(NotificationCenter.default.publisher(for: .voxflowOpenSetup)) { _ in
                    activateAndOpenWindow(id: "setup")
                }
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

                Divider()

                Button("Quit VoxFlow") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: [.command])
            }
        }

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

    private func activateAndOpenWindow(id: String) {
        coordinator.activateForWindow()
        openWindow(id: id)
    }
}
