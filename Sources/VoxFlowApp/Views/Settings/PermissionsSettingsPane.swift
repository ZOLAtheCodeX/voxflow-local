import SwiftUI

/// Settings > Permissions: microphone and accessibility status, with the polling timer.
struct PermissionsSettingsPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var permissionPollTimer: Timer?

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    Text(permissions.microphoneAuthorized ? "Granted" : "Missing")
                        .foregroundStyle(permissions.microphoneAuthorized ? .green : .orange)
                    Button("Request") {
                        coordinator.requestMicrophonePermission()
                        refreshPermissions()
                    }
                }

                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(permissions.accessibilityAuthorized ? "Granted" : "Missing")
                        .foregroundStyle(permissions.accessibilityAuthorized ? .green : .orange)
                    Button("Request") {
                        coordinator.requestAccessibilityPermission()
                        startPermissionPolling()
                    }
                }

                Button("Refresh Permissions") {
                    refreshPermissions()
                }
            }

        }
        .formStyle(.grouped)
        .onAppear { refreshPermissions() }
        .onDisappear {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
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
