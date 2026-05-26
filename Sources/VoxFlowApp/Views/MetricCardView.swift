import SwiftUI

/// Shared metric card used by `DashboardPanelView` and `DashboardWindowView`.
///
/// Renders a label, a prominent value, and an optional detail line in a
/// rounded `VF.cardBackground` surface. Extracted so both dashboards stay
/// visually consistent and any future tweak (typography, padding, corner
/// radius) lands in one place instead of two near-identical inlines.
struct MetricCardView: View {
    let title: String
    let value: String
    let detail: String
    /// Minimum content height. The compact panel uses ~64; the full
    /// window uses ~70 so the value row stays vertically centred even
    /// when the detail line wraps to a second line.
    var minHeight: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(VF.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(VF.titleFont.weight(.bold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(VF.captionFont)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .padding(10)
        .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerMedium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }
}
