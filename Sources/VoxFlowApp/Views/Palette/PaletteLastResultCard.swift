import SwiftUI

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
