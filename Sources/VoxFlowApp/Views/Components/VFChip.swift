import SwiftUI

/// A small tinted label with an optional leading symbol.
struct VFChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = VF.colorNeutral

    var body: some View {
        HStack(spacing: VF.spacingXSmall) {
            if let symbol {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(VF.captionEmphasizedFont)
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, VF.spacingSmall)
        .padding(.vertical, VF.spacingXSmall)
        .background(VF.tintedBackground(tint), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
