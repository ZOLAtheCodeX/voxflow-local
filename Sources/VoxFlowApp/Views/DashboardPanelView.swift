import SwiftUI
import Foundation

struct DashboardPanelView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    var onSwitchToCapture: () -> Void
    var onOpenFullDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Dashboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(sessionDurationText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                metricCard(
                    title: "Captures",
                    value: "\(state.captureCount)",
                    detail: "Local \(state.localCaptureCount) · API \(state.privateAPICaptureCount)"
                )
                metricCard(
                    title: "Transcription",
                    value: "\(state.averageTranscriptionLatencyMs)ms avg",
                    detail: "Last \(state.lastTranscriptionLatencyMs ?? 0)ms"
                )
                metricCard(
                    title: "Insert Success",
                    value: "\(Int((state.insertSuccessRate * 100).rounded()))%",
                    detail: "Fallback \(state.fallbackInsertCount) · Failed \(state.failedInsertCount)"
                )
                metricCard(
                    title: "Approvals",
                    value: "T\(state.approvedTranslationCount) · M\(state.approvedMeetingCount)",
                    detail: "Raw \(state.privacyApproveRawCount) · Redacted \(state.privacyApproveRedactedCount)"
                )
            }

            metricCard(
                title: "Mode Usage",
                value: modeUsageHeadline,
                detail: modeUsageDetail
            )

            metricCard(
                title: "Recommended Profile",
                value: recommendedProfileHeadline,
                detail: recommendedProfileDetail
            )

            HStack {
                Label("Mode: \(state.workflowMode.displayName)", systemImage: "rectangle.3.group")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Label("Provider: \(state.providerMode.displayName)", systemImage: "cpu")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Go To Capture") {
                    onSwitchToCapture()
                }
                .buttonStyle(.borderedProminent)

                Button("Open Full Dashboard") {
                    onOpenFullDashboard()
                }
                .buttonStyle(.bordered)

                Button("Reset Metrics") {
                    coordinator.resetDashboardMetrics()
                }
                .buttonStyle(.bordered)
            }

            if let topApp = state.appInsertStatsSummary.first {
                Text("Top App: \(topApp.appName) · \(Int((topApp.successRate * 100).rounded()))% success")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var sessionDurationText: String {
        let duration = Int(state.sessionDuration)
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "Uptime %02d:%02d", minutes, seconds)
    }

    private var modeUsageHeadline: String {
        let top = state.workflowUsageSummary.first(where: { $0.captures > 0 })
        guard let top else { return "No captures yet" }
        return "\(top.mode.displayName) \(top.captures)x"
    }

    private var modeUsageDetail: String {
        let used = state.workflowUsageSummary.filter { $0.captures > 0 }
        guard !used.isEmpty else { return "Start dictating to build usage history" }
        return used.prefix(3).map { "\($0.mode.displayName) \($0.captures)" }.joined(separator: " · ")
    }

    private var recommendedProfileHeadline: String {
        guard let recommended = state.recommendedProfileFromHistory else {
            return "No benchmark history"
        }
        return recommended.profile.displayName
    }

    private var recommendedProfileDetail: String {
        guard let recommended = state.recommendedProfileFromHistory else {
            return "Run Translate Benchmark to generate recommendation"
        }
        return "avg \(recommended.averageMedianLatencyMs)ms · p95 \(recommended.averageP95LatencyMs)ms · successful \(recommended.successfulRuns)/\(recommended.benchmarkRuns)"
    }

    private func metricCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
