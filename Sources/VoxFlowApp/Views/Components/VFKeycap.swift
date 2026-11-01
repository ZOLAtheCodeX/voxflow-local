import SwiftUI

/// A keyboard shortcut drawn as a key cap, for example "⌘R" or "Fn".
struct VFKeycap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(VF.microFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, VF.spacingXSmall + 2)
            .padding(.vertical, 2)
            .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(VF.hairline, lineWidth: 1)
            }
            .accessibilityLabel("Shortcut \(keys)")
    }
}
