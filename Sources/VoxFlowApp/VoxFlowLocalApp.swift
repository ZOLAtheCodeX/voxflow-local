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
                .task {
                    await MainActor.run {
                        appDelegate.installAutomationURLHandler { url in
                            handleAutomationURL(url)
                        }
                    }
                }
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
                // ⌥⌘2 (not ⌘2) so the shortcut doesn't compete with the
                // second cockpit chip's ⌘2 binding when the cockpit is key.
                .keyboardShortcut("2", modifiers: [.command, .option])

                Button("Open Setup Wizard") {
                    activateAndOpenWindow(id: "setup")
                }
                // ⌥⌘1 (not ⌘1) — same rationale as the dashboard shortcut.
                .keyboardShortcut("1", modifiers: [.command, .option])

                Button("Open Cockpit") {
                    coordinator.cockpit.open()
                    activateAndOpenWindow(id: "cockpit")
                }
                .keyboardShortcut("v", modifiers: [.option, .command])

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

        // Cockpit Layer 0 — long-form workspace, opens via ⌥⌘V or menu.
        Window("VoxFlow Cockpit", id: "cockpit") {
            CockpitWindowView(
                coordinator: coordinator.cockpit,
                state: coordinator.state,
                sessionService: coordinator.cockpitSessionService,
                cockpitCapture: coordinator.cockpitCapture
            )
            .frame(minWidth: 720, minHeight: 480)
        }
    }

    private func activateAndOpenWindow(id: String) {
        coordinator.activateForWindow()
        openWindow(id: id)
    }

    private func handleAutomationURL(_ url: URL) {
        do {
            let command = try AppAutomationCommand(url: url)
            coordinator.handleAutomationCommand(command) { windowID in
                activateAndOpenWindow(id: windowID)
            }
        } catch {
            coordinator.state.statusLine = "Automation URL failed: \(error.localizedDescription)"
        }
    }
}
