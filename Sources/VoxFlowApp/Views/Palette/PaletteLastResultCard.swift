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

/// The idle palette's main card: the outcome of the latest capture from its
/// receipt (outcome, target, time, then the snippet or the reject reason).
/// Insert Again and Copy appear only when `canReinsert`; Details opens the
/// Dashboard, where retained audio can be revealed.
struct PaletteLastResultCard: View {
    let row: CaptureReceiptRowModel?
    let canReinsert: Bool
    let onInsertAgain: () -> Void
    let onCopy: () -> Void
    let onDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingSmall) {
            VFSectionHeader(title: "Last dictation")

            if let row {
                VFStatusBadge(status: PaletteLastResult.headline(for: row), detail: row.relativeTime)
                    .truncationMode(.tail)

                if row.isReject {
                    Text(reasonLine(row))
                        .font(VF.secondaryFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if !row.snippet.isEmpty {
                    Text("\u{201C}\(row.snippet)\u{201D}")
                        .font(VF.bodyFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(row.snippet)
                }
            } else {
                Text("Nothing dictated yet.")
                    .font(VF.secondaryFont)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: VF.spacingSmall) {
                if row != nil && canReinsert {
                    Button("Insert Again", action: onInsertAgain)
                        .help("Insert the newest dictation again")
                    Button("Copy", action: onCopy)
                        .help("Copy the newest dictation")
                }
                Spacer(minLength: 0)
                Button(action: onDetails) {
                    HStack(spacing: VF.spacingXSmall) {
                        Text("Details")
                        Image(systemName: "chevron.right")
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.borderless)
                .help("Open the Dashboard")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(VF.captionEmphasizedFont)
        }
        .padding(VF.spacingMedium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))
    }

    private func reasonLine(_ row: CaptureReceiptRowModel) -> String {
        let reason = PaletteLastResult.rejectReasonText(row.rejectReason)
        return row.audioFileURL == nil ? reason : "\(reason) · Audio kept"
    }
}
