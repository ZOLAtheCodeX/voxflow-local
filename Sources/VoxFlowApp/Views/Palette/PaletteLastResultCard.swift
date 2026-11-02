import SwiftUI

/// What the palette's Last-dictation card says and offers. Pure, so the
/// rule that matters most (Review Focus 3) is unit-tested: Insert Again and
/// Copy act on the newest recent dictation, so they are offered only when the
/// latest receipt is a quick dictation's insertion of that very dictation,
/// and they act on the text the receipt records. Failing that, they act on
/// the current result when the latest insert's text is the current text.
/// After a reject the card shows the reason and no insert action, so an older
/// dictation is never offered as if it were the last one.
enum PaletteLastResult {

    /// What Insert Again and Copy act on.
    enum ReinsertAction: Equatable {
        /// The newest recent dictation (`insertRecentDictation`, which targets
        /// the app it was dictated into), with the inserted mode selected.
        case recent(TranscriptCandidate)
        /// The current result, for Copy only (`copyCurrentText`). Its insert
        /// (`insertCurrentText`) has no target once the session is idle (the
        /// captured target is cleared then), so it would always fail into a
        /// clipboard copy (ruling R51).
        case current

        /// Insert Again is offered only for the recent dictation.
        var offersInsertAgain: Bool {
            if case .recent = self { return true }
            return false
        }

        var offersCopy: Bool { true }

        static func == (a: ReinsertAction, b: ReinsertAction) -> Bool {
            switch (a, b) {
            case (.recent(let x), .recent(let y)): return x.id == y.id && x.selectedMode == y.selectedMode
            case (.current, .current): return true
            default: return false
            }
        }
    }

    /// Rulings R37 and R51: whether the receipt is quick dictation's own
    /// insert. `CaptureReceipt` has no source-kind field; its one structured
    /// view of the source is `sourceLabel` (`SourceLabel.parse`, which the
    /// Dashboard chips use), read through two properties:
    /// - `sourceLabel.appLabel`: only the dictation pipeline's auto-insert
    ///   writes the "Inserted (<level> — <app>)" form, the one form that
    ///   parses to an app label;
    /// - `sourceLabel.tokens`: any other source is kept whole as a single
    ///   token. The palette's review-card insert (`insertCurrentText`) writes
    ///   "review (<level> · <provenance>)", or "review" when there is no
    ///   provenance, and is the other way quick dictation inserts.
    /// The cockpit ("cockpit"), chains, snippets, skills, prompts and
    /// re-inserts match neither. The text match in `reinsertCandidate` still
    /// guards both forms.
    static func isQuickDictationInsert(_ receipt: CaptureReceipt) -> Bool {
        guard receipt.event == .insert else { return false }
        let label = receipt.sourceLabel
        if label.appLabel != nil { return true }
        guard label.tokens.count == 1, let token = label.tokens.first else { return false }
        return token == "review" || token.hasPrefix("review (")
    }

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

    /// A copy of the newest recent dictation whose selected mode is the one
    /// the latest receipt inserted, so Insert Again and Copy act on exactly
    /// the text the card shows. Auto-insert pushes a candidate whose selected
    /// mode is raw while it inserts light or polish text; the copy corrects
    /// that. Nil when there is no receipt, the receipt is a reject or a voice
    /// action, it records other text (a cockpit insert adds nothing to the
    /// recent dictations), it carries no text (digest or none retention), or
    /// it is not quick dictation's own insert (ruling R37: the same text from
    /// the cockpit must not point Insert Again at an older dictation and the
    /// app it was dictated into).
    static func reinsertCandidate(latest receipt: CaptureReceipt?, newest candidate: TranscriptCandidate?) -> TranscriptCandidate? {
        guard let receipt, isQuickDictationInsert(receipt) else { return nil }
        let mode = candidate.flatMap { matchedMode(receiptText: receipt.text ?? "", candidate: $0) }
        guard canReinsert(
                receiptIsReject: receipt.event != .insert,
                hasRecentDictation: candidate != nil,
                newestDictationMatchesReceipt: mode != nil),
              var reinsert = candidate, let mode else { return nil }
        reinsert.selectedMode = mode
        return reinsert
    }

    /// What the card's Insert Again and Copy act on (rulings R36, R37, R51):
    /// the newest recent dictation when `reinsertCandidate` allows it (an
    /// auto-insert or a review-card insert of it); otherwise the current
    /// result, for Copy only, when the latest receipt is an insertion whose
    /// text, trimmed, is the current text (a Private API dictation never
    /// enters the recent dictations). Nil after a reject or a voice action,
    /// without text, or when the texts differ.
    static func reinsertAction(
        latest receipt: CaptureReceipt?, newest candidate: TranscriptCandidate?, displayText: String
    ) -> ReinsertAction? {
        if let reinsert = reinsertCandidate(latest: receipt, newest: candidate) {
            return .recent(reinsert)
        }
        guard let receipt, receipt.event == .insert else { return nil }
        let inserted = (receipt.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let current = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inserted.isEmpty, inserted == current else { return nil }
        return .current
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
/// Insert Again appears only when `canInsertAgain` and Copy only when
/// `canCopy` (`PaletteLastResult.reinsertAction`); Details opens the
/// Dashboard, where retained audio can be revealed.
struct PaletteLastResultCard: View {
    let row: CaptureReceiptRowModel?
    let canInsertAgain: Bool
    let canCopy: Bool
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
                if row != nil && canInsertAgain {
                    Button("Insert Again", action: onInsertAgain)
                        .help("Insert the newest dictation again")
                }
                if row != nil && canCopy {
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
