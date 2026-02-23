import SwiftUI

struct ConfidenceBadge: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(Int(confidence * 100))%")
                .font(VF.captionFont)
                .foregroundStyle(.secondary)
        }
    }

    var color: Color {
        if confidence >= 0.7 { return .green }
        if confidence >= 0.4 { return .yellow }
        return .red
    }
}
