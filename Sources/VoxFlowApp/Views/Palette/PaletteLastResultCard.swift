import SwiftUI

/// What the palette's Last-dictation card says and offers. Pure, so the
/// rule that matters most (Review Focus 3) is unit-tested: Insert Again and
/// Copy act on the newest recent dictation, so they are offered only when the
/// latest receipt is an insertion of that very dictation, and they act on
/// the text the receipt records. After a reject the card shows the reason
/// and no insert action, so an older dictation is never offered as if it were
/// the last one.
enum PaletteLastResult {

    static func canReinsert(
        receiptIsReject: Bool, hasRecentDictation: Bool, newestDictationMatchesReceipt: Bool
    ) -> Bool {
        !receiptIsReject && hasRecentDictation && newestDictationMatchesReceipt
    }

    /// The cleanup mode whose text this receipt records as inserted, or nil.
    /// The receipt's `text` is the full inserted text (the audit log writes
    /// it verbatim under the default retention), so both sides are compared
    /// whole after trimming whitespace and newlines. The candidate's selected
    /// mode wins when several modes share the text. Empty text matches
    /// nothing: when unsure, no Insert Again.
    static func matchedMode(receiptText: String, candidate: TranscriptCandidate) -> CleanupMode? {
        let inserted = receiptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty else { return nil }
        let order = [candidate.selectedMode] + CleanupMode.allCases.filter { $0 != candidate.selectedMode }
        return order.first {
            candidate.text(for: $0).trimmingCharacters(in: .whitespacesAndNewlines) == inserted
        }
    }

    /// What Insert Again and Copy act on: a copy of the newest recent
    /// dictation whose selected mode is the one the latest receipt inserted,
    /// so both act on exactly the text the card shows. Auto-insert pushes a
    /// candidate whose selected mode is raw while it inserts light or polish
    /// text; the copy corrects that. Nil, so no Insert Again, when there is
    /// no receipt, the receipt is a reject or a voice action, it records
    /// other text (a cockpit insert adds nothing to the recent dictations),
    /// or it carries no text (digest or none retention).
    static func reinsertCandidate(latest receipt: CaptureReceipt?, newest candidate: TranscriptCandidate?) -> TranscriptCandidate? {
        guard let receipt else { return nil }
        let mode = candidate.flatMap { matchedMode(receiptText: receipt.text ?? "", candidate: $0) }
        guard canReinsert(
                receiptIsReject: receipt.event != .insert,
                hasRecentDictation: candidate != nil,
                newestDictationMatchesReceipt: mode != nil),
              var reinsert = candidate, let mode else { return nil }
        reinsert.selectedMode = mode
        return reinsert
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
        let reason = VFCopy.rejectReasonText(row.rejectReason)
        return row.audioFileURL == nil ? reason : "\(reason) · Audio kept"
    }
}
