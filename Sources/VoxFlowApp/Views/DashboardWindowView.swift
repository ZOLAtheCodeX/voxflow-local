import SwiftUI

struct DashboardWindowView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricsGrid
                modeUsageSection
                benchmarkRecommendationSection
                compatibilitySection
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("VoxFlow Dashboard")
                    .font(.system(size: 22, weight: .bold))
                Text("Session telemetry and app compatibility")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                Text("Uptime \(sessionDurationText)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Button("Reset Session Metrics") {
                    coordinator.resetDashboardMetrics()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(title: "Captures", value: "\(state.captureCount)", detail: "Local \(state.localCaptureCount) · API \(state.privateAPICaptureCount)")
            statCard(title: "Transcription", value: "\(state.averageTranscriptionLatencyMs)ms avg", detail: "Last \(state.lastTranscriptionLatencyMs ?? 0)ms")
            statCard(title: "Insert Success", value: "\(Int((state.insertSuccessRate * 100).rounded()))%", detail: "Fallback \(state.fallbackInsertCount) · Failed \(state.failedInsertCount)")
            statCard(title: "Approvals", value: "T\(state.approvedTranslationCount) · M\(state.approvedMeetingCount)", detail: "Raw \(state.privacyApproveRawCount) · Redacted \(state.privacyApproveRedactedCount)")
        }
    }

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App Compatibility Matrix")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            if state.appInsertStatsSummary.isEmpty {
                Text("No insert attempts recorded yet. Dictate and insert text to build compatibility data.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    headerRow
                    ForEach(state.appInsertStatsSummary) { stats in
                        appRow(stats)
                    }
                }
            }
        }
    }

    private var modeUsageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mode Usage")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            let used = state.workflowUsageSummary.filter { $0.captures > 0 }
            if used.isEmpty {
                Text("No mode usage captured yet. Dictate in Dictation, Translate, or Meeting mode to populate this section.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("Mode")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Captures")
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)

                    ForEach(used) { metric in
                        HStack {
                            Text(metric.mode.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(metric.captures)")
                                .frame(width: 90, alignment: .trailing)
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var benchmarkRecommendationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Benchmark Recommendation")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            if let recommended = state.recommendedProfileFromHistory {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recommended: \(recommended.profile.displayName)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("avg median \(recommended.averageMedianLatencyMs)ms · avg p95 \(recommended.averageP95LatencyMs)ms")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Successful runs \(recommended.successfulRuns)/\(recommended.benchmarkRuns) · placeholders \(recommended.placeholderRuns)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text("No benchmark history yet. Run Translate Benchmark in Settings to generate a recommendation.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if !state.benchmarkHistoryByProfile.isEmpty {
                VStack(spacing: 8) {
                    HStack {
                        Text("Profile")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("avg med")
                            .frame(width: 80, alignment: .trailing)
                        Text("avg p95")
                            .frame(width: 80, alignment: .trailing)
                        Text("succ/run")
                            .frame(width: 90, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)

                    ForEach(historyRows) { row in
                        HStack {
                            Text(row.profile.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(row.averageMedianLatencyMs)ms")
                                .frame(width: 80, alignment: .trailing)
                            Text("\(row.averageP95LatencyMs)ms")
                                .frame(width: 80, alignment: .trailing)
                            Text("\(row.successfulRuns)/\(row.benchmarkRuns)")
                                .frame(width: 90, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var historyRows: [TranslationBenchmarkHistoryStats] {
        state.benchmarkHistoryByProfile.values.sorted {
            if $0.recommendationScore == $1.recommendationScore {
                return $0.profile.displayName < $1.profile.displayName
            }
            return $0.recommendationScore < $1.recommendationScore
        }
    }

    private var headerRow: some View {
        HStack {
            Text("App")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Success")
                .frame(width: 70, alignment: .trailing)
            Text("Fallback")
                .frame(width: 70, alignment: .trailing)
            Text("Failed")
                .frame(width: 60, alignment: .trailing)
            Text("Status")
                .frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    private func appRow(_ stats: AppInsertStats) -> some View {
        let status = compatibilityStatus(for: stats)
        return HStack {
            Text(stats.appName)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(stats.successCount)")
                .frame(width: 70, alignment: .trailing)
            Text("\(stats.fallbackCount)")
                .frame(width: 70, alignment: .trailing)
            Text("\(stats.failedCount)")
                .frame(width: 60, alignment: .trailing)
            Text(status.label)
                .frame(width: 110, alignment: .trailing)
                .foregroundStyle(status.color)
                .font(.system(size: 11, weight: .semibold))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sessionDurationText: String {
        let duration = Int(state.sessionDuration)
        let hours = duration / 3600
        let minutes = (duration % 3600) / 60
        let seconds = duration % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func statCard(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .bold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(12)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func compatibilityStatus(for stats: AppInsertStats) -> (label: String, color: Color) {
        if stats.totalAttempts == 0 {
            return ("No Data", .secondary)
        }
        if stats.successRate >= 0.95 && stats.failedCount == 0 {
            return ("Excellent", .green)
        }
        if stats.successRate >= 0.80 {
            return ("Good", .blue)
        }
        if stats.successRate >= 0.60 {
            return ("Needs Tuning", .orange)
        }
        return ("Unstable", .red)
    }
}
