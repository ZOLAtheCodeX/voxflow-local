import SwiftUI

/// What the palette's Last-dictation card says and offers. Pure, so the
/// rule that matters most (Review Focus 3) is unit-tested: Insert Again and
/// Copy act on the newest recent dictation, so they are offered only when the
/// latest receipt is an insertion. After a reject the card shows the reason
/// and no insert action, so an older dictation is never offered as if it were
/// the last one.
enum PaletteLastResult {

    static func canReinsert(receiptIsReject: Bool, hasRecentDictation: Bool) -> Bool {
        !receiptIsReject && hasRecentDictation
    }

    /// The same rule read from the latest receipt itself. Only an insertion
    /// counts: no receipt, a reject, or a voice action (which inserts no
    /// text, so the newest dictation predates it) never offers Insert Again.
    static func canReinsert(latest receipt: CaptureReceipt?, hasRecentDictation: Bool) -> Bool {
        guard let receipt else { return false }
        return canReinsert(receiptIsReject: receipt.event != .insert, hasRecentDictation: hasRecentDictation)
    }

    /// The first chip `CaptureReceiptRowModel` gives a computer-action
    /// receipt, which the glossary calls a voice action.
    private static let voiceActionChip = "Computer action"

    /// The card's first line.
    static func headline(for row: CaptureReceiptRowModel) -> VFStatus {
        if row.chips.first == voiceActionChip {
            let outcome = row.chips.dropFirst().first ?? "Status unavailable"
            return VFStatus(row.isReject ? .attention : .info, "Voice action: \(outcome)")
        }
        if row.isReject {
            return VFStatus(.attention, "Not inserted")
        }
        if let target = row.targetLabel, !target.isEmpty {
            return VFStatus(.ready, "Inserted in \(target)")
        }
        return VFStatus(.ready, "Inserted")
    }

    /// A receipt's reject reason code in plain words. Unknown codes are
    /// shown with underscores as spaces rather than hidden.
    static func rejectReasonText(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "No reason recorded" }
        switch code {
        case "silence": return "No speech detected"
        case "empty", "placeholder": return "Nothing was transcribed"
        case "hallucination_filter": return "Filtered out as likely not speech"
        case "low_confidence": return "Recognition confidence too low"
        case "transcription_error": return "Transcription failed"
        case "interrupted_tail": return "Recording was interrupted"
        case "capture_stalled": return "The microphone delivered no audio"
        case "device_changed": return "The audio device changed"
        default:
            let words = code.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }
}

extension CommandPaletteView {
    /// Persistent last-capture provenance row — the pipeline stage card
    /// vanishes the instant an insert lands; this stays until the next
    /// capture replaces it. Rejects render tinted with their reason.
    @ViewBuilder var lastCaptureRow: some View {
        if let receipt = receiptStore.latest {
            let row = CaptureReceiptRowModel(receipt: receipt)
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: row.isReject ? "xmark.circle" : "checkmark.circle")
                    .font(VF.captionFont)
                    .foregroundStyle(row.isReject ? VF.colorWarning : VF.colorSuccess)
                Text(row.relativeTime)
                    .font(VF.microFont)
                    .foregroundStyle(.secondary)
                ForEach(row.chips, id: \.self) { chip in
                    Text(chip)
                        .font(VF.microFont)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(VF.cardBackground, in: Capsule())
                }
                if let target = row.targetLabel {
                    Text(target)
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                }
                if let reason = row.rejectReason {
                    Text(reason)
                        .font(VF.microFont)
                        .foregroundStyle(VF.colorWarning)
                }
                Text(row.snippet)
                    .font(VF.microFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.isReject
                ? "Last capture rejected: \(row.rejectReason ?? "unknown")"
                : "Last capture inserted via \(row.chips.joined(separator: ", "))")
        }
    }
}
