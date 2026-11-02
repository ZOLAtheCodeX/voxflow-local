import SwiftUI

/// What the Dashboard shows and how it words a row. Pure, so the conditional
/// sections and the recent-capture wording are unit-tested without a window.
enum DashboardRules {

    /// The Approvals card counts consent prompts that only translate and
    /// meeting mode raise, so it appears only while one of them is enabled.
    static func showsApprovals(translationEnabled: Bool, meetingEnabled: Bool) -> Bool {
        translationEnabled || meetingEnabled
    }

    /// Mode usage and the benchmark are for the experimental modes. They show
    /// while any of those modes is enabled, or when benchmark history exists
    /// from an earlier run.
    static func showsExperimentalSections(
        translationEnabled: Bool, meetingEnabled: Bool, promptEnabled: Bool, hasBenchmarkHistory: Bool
    ) -> Bool {
        translationEnabled || meetingEnabled || promptEnabled || hasBenchmarkHistory
    }

    // MARK: - App compatibility

    struct Compatibility: Equatable {
        let label: String
        let color: Color
    }

    /// How well inserts into one app have worked. "Good" uses the info token.
    static func compatibility(for stats: AppInsertStats) -> Compatibility {
        if stats.totalAttempts == 0 {
            return Compatibility(label: "No data", color: VF.colorNeutral)
        }
        if stats.successRate >= 0.95 && stats.failedCount == 0 {
            return Compatibility(label: "Excellent", color: VF.colorSuccess)
        }
        if stats.successRate >= 0.80 {
            return Compatibility(label: "Good", color: VF.colorInfo)
        }
        if stats.successRate >= 0.60 {
            return Compatibility(label: "Needs tuning", color: VF.colorWarning)
        }
        return Compatibility(label: "Unstable", color: VF.colorError)
    }

    // MARK: - Recent captures

    private static let voiceActionChip = "Computer action"

    /// Receipts call a voice action a "Computer action"; the glossary does not.
    static func chipText(_ chip: String) -> String {
        chip == voiceActionChip ? "Voice action" : chip
    }

    /// The chips on a row's first line. A rejected dictation's only chip is
    /// the raw "Rejected (reason_code)" label, which the second line already
    /// says in words, so it is dropped. A failed voice action keeps its chips
    /// (action and outcome).
    static func chips(for row: CaptureReceiptRowModel) -> [String] {
        if row.isReject && row.chips.first != voiceActionChip { return [] }
        return row.chips.map(chipText)
    }

    /// The row's second line: the reject reason in words (with a note when the
    /// audio was kept), otherwise the text that was inserted. `audioAvailable`
    /// is true when the retained clip still exists on disk.
    static func secondLine(for row: CaptureReceiptRowModel, audioAvailable: Bool) -> String {
        if row.isReject {
            if let code = row.rejectReason, !code.isEmpty {
                let reason = VFCopy.rejectReasonText(code)
                return audioAvailable ? "\(reason) \u{00B7} Audio kept" : reason
            }
            // A failed voice action has no reject code; its name says which.
            return row.snippet.isEmpty ? VFCopy.rejectReasonText(nil) : row.snippet
        }
        guard !row.snippet.isEmpty else { return "" }
        return row.chips.first == voiceActionChip ? row.snippet : "\u{201C}\(row.snippet)\u{201D}"
    }
}
