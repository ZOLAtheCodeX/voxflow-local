import SwiftUI

/// The Recent row's copy, moved here unchanged so the Last-dictation card
/// can share it. It writes `NSPasteboard.general` directly, as it always
/// has; routing it through `SystemClipboard.copy` is an open follow-up.
/// Tests never call it.
@MainActor
enum PaletteRecentCopy {
    static func copy(_ candidate: TranscriptCandidate, state: AppState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate.text(for: candidate.selectedMode), forType: .string)
        state.statusLine = "Copied to clipboard"
    }
}

/// The palette's Recent tab: this session's dictations, newest first, each
/// with Insert (`insertRecentDictation`) and Copy, and Clear History behind
/// a confirmation (`clearSessionHistory`).
struct PaletteRecentList: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var state: AppState

    @State private var showClearHistoryAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if state.recentDictations.isEmpty {
                VFEmptyState(
                    title: "No recent dictations",
                    symbol: "clock",
                    message: "Dictations from this session appear here.")
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: VF.spacingXSmall + 2) {
                        ForEach(state.recentDictations) { candidate in
                            recentRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 200)

                Button("Clear History") {
                    showClearHistoryAlert = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .alert("Clear History", isPresented: $showClearHistoryAlert) {
                    Button("Clear All", role: .destructive) {
                        coordinator.clearSessionHistory()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Clear all recent dictations? This cannot be undone.")
                }
            }
        }
        .padding(VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))
    }

    private func recentRow(_ candidate: TranscriptCandidate) -> some View {
        HStack(alignment: .top, spacing: VF.spacingSmall) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(candidate.rawText.prefix(80)) + (candidate.rawText.count > 80 ? "\u{2026}" : ""))
                    .font(VF.labelFont)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(candidate.selectedMode.displayName)
                        .font(VF.captionEmphasizedFont)
                        .foregroundStyle(.secondary)
                    if candidate.confidence > 0 {
                        ConfidenceBadge(confidence: candidate.confidence)
                    }
                    Text(relativeTime(candidate.timestamp))
                        .font(VF.captionFont)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            VStack(spacing: VF.spacingXSmall) {
                Button("Insert") {
                    coordinator.insertRecentDictation(candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy") {
                    PaletteRecentCopy.copy(candidate, state: state)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(VF.spacingSmall)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: VF.cornerSmall, style: .continuous))
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}
