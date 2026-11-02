import SwiftUI
import AppKit

/// The Dashboard window: health first, recent captures second (the view used
/// to check a lost dictation), then session metrics and app compatibility.
/// Experimental-mode cards appear only when those modes are in use.
struct DashboardWindowView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState
    @ObservedObject var receiptStore: InsertionReceiptStore

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VF.spacingLarge) {
                header
                healthStrip
                recentCapturesSection
                metricsSection
                compatibilitySection
                if DashboardRules.showsExperimentalSections(
                    translationEnabled: state.translationModeEnabled,
                    meetingEnabled: state.meetingModeEnabled,
                    promptEnabled: state.promptModeEnabled,
                    hasBenchmarkHistory: !state.benchmarkHistoryByProfile.isEmpty
                ) {
                    modeUsageSection
                    benchmarkRecommendationSection
                }
            }
            .padding(VF.spacingLarge)
        }
        .background(VF.surfaceWindow)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: VF.spacingXSmall) {
                Text("Dashboard")
                    .font(VF.displayFont)
                Text("This session, since \(Text(state.launchedAt, style: .time))")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reset Metrics") {
                coordinator.resetDashboardMetrics()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Health

    private var healthStrip: some View {
        let readiness = state.backendReadiness
        let provider = readiness.activePolishProvider
        let cleanupLabel = VFCopy.cleanupProviderLabel(provider: provider, model: readiness.activePolishModel)
        let cleanup = VFStatus(VFCopy.isCleanupDegraded(provider: provider) ? .attention : .ready, cleanupLabel)
        return VStack(alignment: .leading, spacing: VF.spacingSmall) {
            HStack(spacing: VF.spacingLarge) {
                VFStatusBadge(
                    status: VFStatus.engine(readiness, backendShouldRun: state.backendShouldRun))
                VFStatusBadge(
                    status: VFStatus.speechModel(readiness),
                    detail: readiness.activeSTTModel.isEmpty ? nil : readiness.activeSTTModel)
                VFStatusBadge(status: cleanup)
                Spacer(minLength: 0)
            }
            if let issue = readiness.readinessIssue, !issue.isEmpty {
                Text("Engine issue: \(issue)")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: cardShape)
    }

    // MARK: - Recent captures

    /// Pipeline provenance history: the newest receipts from insertions.jsonl,
    /// rejects included. Read-only; the file is written by InsertionAuditLog.
    private var recentCapturesSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "Recent captures")

            if receiptStore.receipts.isEmpty {
                Text("No captures yet. Dictations that reach transcription appear here.")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(VF.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vfSurface(.card, in: cardShape)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    let receipts = Array(receiptStore.receipts.enumerated())
                    ForEach(receipts, id: \.offset) { index, receipt in
                        if index > 0 {
                            Divider()
                        }
                        recentCaptureRow(receipt)
                    }
                }
                .padding(.horizontal, VF.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfSurface(.card, in: cardShape)
            }
        }
        .onAppear { receiptStore.refresh() }
        .onChange(of: state.captureCount) { _, _ in receiptStore.refresh() }
        .onChange(of: state.statusLine) { _, _ in receiptStore.refresh() }
    }

    private func recentCaptureRow(_ receipt: CaptureReceipt) -> some View {
        let row = CaptureReceiptRowModel(receipt: receipt)
        let outcome = PaletteLastResult.headline(for: row)
        let audioURL = row.audioFileURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let second = DashboardRules.secondLine(for: row, audioAvailable: audioURL != nil)
        return HStack(alignment: .top, spacing: VF.spacingSmall) {
            Image(systemName: outcome.symbol)
                .font(VF.captionFont)
                .foregroundStyle(outcome.color)
                .frame(width: 16)
                .accessibilityLabel(outcome.label)
            VStack(alignment: .leading, spacing: VF.spacingXSmall) {
                HStack(spacing: VF.spacingSmall) {
                    Text(row.relativeTime)
                        .font(VF.monoCaptionFont)
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    ForEach(DashboardRules.chips(for: row), id: \.self) { chip in
                        VFChip(text: chip)
                    }
                    if let target = row.targetLabel, !target.isEmpty {
                        Text(target)
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(VF.monoCaptionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                if !second.isEmpty {
                    Text(second)
                        .font(VF.secondaryFont)
                        .foregroundStyle(row.isReject ? VF.colorWarning : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(second)
                }
            }
            if let url = audioURL {
                // Rejects that retained their audio (RejectedAudioStore ring)
                // get a one-click path to the WAV for forensic triage.
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Image(systemName: "waveform.circle")
                }
                .buttonStyle(.plain)
                .help("Reveal retained audio in Finder")
                .accessibilityLabel("Reveal retained audio in Finder")
            }
        }
        .padding(.vertical, VF.spacingSmall)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "This session")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200), spacing: VF.spacingMedium)],
                spacing: VF.spacingMedium
            ) {
                MetricCardView(
                    title: "Captures", value: "\(state.captureCount)",
                    detail: "Local \(state.localCaptureCount) \u{00B7} Private API \(state.privateAPICaptureCount)",
                    minHeight: 74)
                MetricCardView(
                    title: "Latency", value: "\(state.averageTranscriptionLatencyMs) ms avg",
                    detail: state.lastTranscriptionLatencyMs.map { "Last \($0) ms" } ?? "No capture yet",
                    minHeight: 74)
                MetricCardView(
                    title: "Insert success", value: "\(Int((state.insertSuccessRate * 100).rounded()))%",
                    detail: "Fallback \(state.fallbackInsertCount) \u{00B7} Failed \(state.failedInsertCount)",
                    minHeight: 74)
                if DashboardRules.showsApprovals(
                    translationEnabled: state.translationModeEnabled, meetingEnabled: state.meetingModeEnabled
                ) {
                    MetricCardView(
                        title: "Approvals",
                        value: "Translate \(state.approvedTranslationCount) \u{00B7} Meeting \(state.approvedMeetingCount)",
                        detail: "Raw \(state.privacyApproveRawCount) \u{00B7} Redacted \(state.privacyApproveRedactedCount)",
                        minHeight: 74)
                }
            }
        }
    }

    // MARK: - App compatibility

    private var compatibilitySection: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "App compatibility")

            if state.appInsertStatsSummary.isEmpty {
                Text("No inserts recorded yet. Dictate into an app to see how well it works there.")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(VF.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vfSurface(.card, in: cardShape)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: VF.spacingMedium, verticalSpacing: VF.spacingSmall) {
                    GridRow {
                        Text("App")
                            .gridColumnAlignment(.leading)
                        Text("Success")
                        Text("Fallback")
                        Text("Failed")
                        Text("Status")
                    }
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellUnsizedAxes(.horizontal)

                    ForEach(state.appInsertStatsSummary) { stats in
                        let status = DashboardRules.compatibility(for: stats)
                        GridRow {
                            Text(stats.appName)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(stats.successCount)")
                            Text("\(stats.fallbackCount)")
                            Text("\(stats.failedCount)")
                            Text(status.label)
                                .font(VF.captionEmphasizedFont)
                                .foregroundStyle(status.color)
                        }
                        .font(VF.secondaryFont)
                    }
                }
                .padding(VF.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfSurface(.card, in: cardShape)
            }
        }
    }

    // MARK: - Experimental modes

    private var modeUsageSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "Mode usage")

            let used = state.workflowUsageSummary.filter { $0.captures > 0 }
            if used.isEmpty {
                Text("No mode usage yet. Dictate in Translate, Meeting or Prompt mode to fill this in.")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(VF.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vfSurface(.card, in: cardShape)
            } else {
                Grid(alignment: .trailing, horizontalSpacing: VF.spacingMedium, verticalSpacing: VF.spacingSmall) {
                    GridRow {
                        Text("Mode")
                            .gridColumnAlignment(.leading)
                        Text("Captures")
                    }
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellUnsizedAxes(.horizontal)

                    ForEach(used) { metric in
                        GridRow {
                            Text(metric.mode.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(metric.captures)")
                        }
                        .font(VF.secondaryFont)
                    }
                }
                .padding(VF.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfSurface(.card, in: cardShape)
            }
        }
    }

    private var benchmarkRecommendationSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "Benchmark recommendation")

            if let recommended = state.recommendedProfileFromHistory {
                VStack(alignment: .leading, spacing: VF.spacingSmall) {
                    Text("Recommended: \(recommended.profile.displayName)")
                        .font(VF.bodyEmphasizedFont)
                    Text("Median \(recommended.averageMedianLatencyMs) ms \u{00B7} 95th percentile \(recommended.averageP95LatencyMs) ms")
                        .font(VF.secondaryFont)
                        .foregroundStyle(.secondary)
                    Text("Successful runs \(recommended.successfulRuns) of \(recommended.benchmarkRuns) \u{00B7} Placeholder runs \(recommended.placeholderRuns)")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }
                .padding(VF.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VF.tintedBackground(VF.colorSuccess, opacity: 0.10), in: cardShape)
            } else {
                Text("No benchmark history yet. Run Translate Benchmark in Settings, Models to get a recommendation.")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
                    .padding(VF.spacingMedium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .vfSurface(.card, in: cardShape)
            }

            if !state.benchmarkHistoryByProfile.isEmpty {
                Grid(alignment: .trailing, horizontalSpacing: VF.spacingMedium, verticalSpacing: VF.spacingSmall) {
                    GridRow {
                        Text("Profile")
                            .gridColumnAlignment(.leading)
                        Text("Median")
                        Text("95th percentile")
                        Text("Successful runs")
                    }
                    .font(VF.captionEmphasizedFont)
                    .foregroundStyle(.secondary)

                    Divider()
                        .gridCellUnsizedAxes(.horizontal)

                    ForEach(historyRows) { row in
                        GridRow {
                            Text(row.profile.displayName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(row.averageMedianLatencyMs) ms")
                            Text("\(row.averageP95LatencyMs) ms")
                            Text("\(row.successfulRuns) of \(row.benchmarkRuns)")
                        }
                        .font(VF.secondaryFont)
                    }
                }
                .padding(VF.spacingMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .vfSurface(.card, in: cardShape)
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
}
