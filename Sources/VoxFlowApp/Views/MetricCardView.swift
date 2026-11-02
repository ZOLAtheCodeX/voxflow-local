import SwiftUI

/// Metric card used by `DashboardWindowView`.
///
/// Renders a label, a prominent value, and an optional detail line in a
/// rounded card surface. Extracted so any future tweak (typography, padding,
/// corner radius) lands in one place.
struct MetricCardView: View {
    let title: String
    let value: String
    let detail: String
    /// Minimum content height. The Dashboard uses ~74 so the value row stays
    /// vertically centred even when the detail line wraps to a second line.
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
        .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerMedium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value). \(detail)")
    }
}
