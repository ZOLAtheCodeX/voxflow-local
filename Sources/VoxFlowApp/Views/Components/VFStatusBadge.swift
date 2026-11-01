import SwiftUI

/// A status as symbol + word (+ optional detail). Static: it never animates.
/// One combined accessibility label so VoiceOver reads it as a single phrase.
struct VFStatusBadge: View {
    let status: VFStatus
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .font(VF.captionEmphasizedFont)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            Text(status.label)
                .font(VF.captionEmphasizedFont)
                .foregroundStyle(status.color)
            if let detail, !detail.isEmpty {
                Text("· \(detail)")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let detail, !detail.isEmpty {
            return "\(status.label), \(detail)"
        }
        return status.label
    }
}
