import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    @State private var permissions = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @State private var backendHealth: [String: String] = [:]
    @State private var isCheckingHealth = false
    @State private var healthStatusLine = "Not checked yet"
    @State private var didRunHealthCheck = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                permissionsCard
                backendCard
                calibrationCard
                validationCard
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshPermissions()
            Task { await runHealthCheckIfNeeded() }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Setup Wizard")
                .font(.system(size: 22, weight: .bold))
            Text("Complete permissions, backend readiness, and calibration before first use.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                statusPill(
                    title: "Permissions",
                    ok: permissions.microphoneAuthorized && permissions.accessibilityAuthorized
                )
                statusPill(
                    title: "Backend",
                    ok: backendHealth["service_status"] == "ok" && backendHealth["model_loaded"] == "true"
                )
                statusPill(
                    title: "Calibration",
                    ok: state.onboardingPhase == .complete
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Permissions")
                .font(.system(size: 15, weight: .semibold))

            HStack {
                Text("Microphone")
                Spacer()
                Text(permissions.microphoneAuthorized ? "Granted" : "Missing")
                    .foregroundStyle(permissions.microphoneAuthorized ? .green : .orange)
            }

            HStack {
                Text("Accessibility")
                Spacer()
                Text(permissions.accessibilityAuthorized ? "Granted" : "Missing")
                    .foregroundStyle(permissions.accessibilityAuthorized ? .green : .orange)
            }

            HStack(spacing: 8) {
                Button("Request Microphone") {
                    coordinator.requestMicrophonePermission()
                }
                .buttonStyle(.borderedProminent)

                Button("Request Accessibility") {
                    coordinator.requestAccessibilityPermission()
                }
                .buttonStyle(.borderedProminent)

                Button("Refresh") {
                    refreshPermissions()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Local Backend Readiness")
                .font(.system(size: 15, weight: .semibold))

            Text("Safe mode: \(state.voxtralSafeModeEnabled ? "ON (recommended on 16GB)" : "OFF (pure Voxtral primary attempt)")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(healthStatusLine)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(backendHealth["model_loaded"] == "true" ? .green : .orange)

            if didRunHealthCheck {
                VStack(alignment: .leading, spacing: 4) {
                    healthLine("Service", backendHealth["service_status"] ?? "unknown")
                    healthLine("Ready for dictation", backendHealth["ready_for_dictation"] ?? "unknown")
                    healthLine("Model loaded", backendHealth["model_loaded"] ?? "unknown")
                    healthLine("Backend", backendHealth["stt_backend"] ?? "unknown")
                    healthLine("Active model", backendHealth["active_stt_model"] ?? "unknown")
                    healthLine("Fallback active", backendHealth["stt_fallback_active"] ?? "unknown")
                    healthLine("Offline mode", backendHealth["offline_mode"] ?? "unknown")
                    if let issues = backendHealth["issues"], !issues.isEmpty {
                        healthLine("Issues", issues)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Start Backend") {
                    coordinator.startBackend()
                    Task { await runHealthCheckAfterDelay() }
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task { await runHealthCheck() }
                } label: {
                    HStack {
                        if isCheckingHealth {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isCheckingHealth ? "Checking..." : "Run Health Check")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isCheckingHealth)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("3. Voice Calibration")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(state.onboardingPhase == .complete ? "Complete" : "Required")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((state.onboardingPhase == .complete ? Color.green : Color.orange).opacity(0.15))
                    .foregroundStyle(state.onboardingPhase == .complete ? .green : .orange)
                    .clipShape(Capsule())
            }

            if state.onboardingPhase == .calibrating {
                OnboardingCalibrationView(coordinator: coordinator, state: state)
                    .padding(.top, 4)
            } else {
                Text("Calibration is complete. You can rerun it if dictation quality is poor.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Start / Restart Calibration") {
                    coordinator.restartOnboardingCalibration()
                }
                .buttonStyle(.borderedProminent)

                Button("Mark Complete") {
                    coordinator.completeOnboardingManually()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var validationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("4. Functional Check")
                .font(.system(size: 15, weight: .semibold))

            Text("Focus any text field (Notes, browser input, chat app), then hold `\(state.dictationHotkeyPreset.displayName)` to dictate and release to insert.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if state.canStartCaptureForDictation {
                Text("Target ready in \(state.focusTarget.appName ?? "active app").")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            } else {
                Text("No active text cursor/field detected yet.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Button("Run Full Setup Reset") {
                coordinator.restartOnboardingCalibration()
                coordinator.startBackend()
                refreshPermissions()
                Task { await runHealthCheckAfterDelay() }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusPill(title: String, ok: Bool) -> some View {
        Text("\(title): \(ok ? "OK" : "Pending")")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background((ok ? Color.green : Color.orange).opacity(0.18))
            .foregroundStyle(ok ? .green : .orange)
            .clipShape(Capsule())
    }

    private func healthLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(title):")
                .fontWeight(.semibold)
            Text(value)
                .lineLimit(2)
        }
    }

    private func refreshPermissions() {
        permissions = coordinator.permissionSnapshot()
    }

    private func runHealthCheckIfNeeded() async {
        guard !didRunHealthCheck else { return }
        await runHealthCheck()
    }

    private func runHealthCheckAfterDelay() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        await runHealthCheck()
    }

    private func runHealthCheck() async {
        guard !isCheckingHealth else { return }
        isCheckingHealth = true
        defer { isCheckingHealth = false }
        refreshPermissions()

        do {
            let readiness = try await BackendAPIClient.ready()
            backendHealth = [
                "service_status": readiness.serviceStatus,
                "ready_for_dictation": String(readiness.readyForDictation).lowercased(),
                "model_loaded": String(readiness.activeSttModelLoaded).lowercased(),
                "stt_backend": readiness.sttBackend,
                "active_stt_model": readiness.activeSttModel,
                "stt_fallback_active": String(readiness.sttFallbackActive).lowercased(),
                "offline_mode": String(readiness.offlineMode).lowercased(),
                "issues": readiness.issues.joined(separator: "; "),
            ]
            didRunHealthCheck = true
            if readiness.readyForDictation {
                healthStatusLine = "Backend ready: model loaded and healthy."
            } else {
                let issue = readiness.issues.first ?? "active STT model is not loaded"
                healthStatusLine = "Backend reachable, not ready: \(issue)"
            }
        } catch {
            backendHealth = [:]
            didRunHealthCheck = true
            healthStatusLine = "Backend unreachable. Start backend and retry."
        }
    }
}
