import SwiftUI

extension CommandPaletteView {
    var recentDictationsPanel: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            if state.recentDictations.isEmpty {
                Text("No recent dictations this session.")
                    .font(VF.bodyFont)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
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
    }

    private func recentRow(_ candidate: TranscriptCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(candidate.rawText.prefix(80)) + (candidate.rawText.count > 80 ? "..." : ""))
                    .font(VF.labelFont)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(candidate.selectedMode.displayName)
                        .font(VF.captionFont.weight(.medium))
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

            VStack(spacing: 4) {
                Button("Insert") {
                    coordinator.insertRecentDictation(candidate)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(candidate.text(for: candidate.selectedMode), forType: .string)
                    state.statusLine = "Copied to clipboard"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: VF.cornerSmall))
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}
