import SwiftUI

struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(percent)%")
                .font(VF.captionFont)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Confidence \(percent) percent")
    }

    private var percent: Int {
        Int((confidence * 100).rounded())
    }

    var color: Color {
        if confidence >= 0.7 { return VF.colorSuccess }
        if confidence >= 0.4 { return VF.colorWarning }
        return VF.colorError
    }
}
