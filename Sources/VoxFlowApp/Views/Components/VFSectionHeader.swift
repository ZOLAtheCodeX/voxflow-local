import SwiftUI

/// A section title in sentence case, exposed to VoiceOver as a heading.
struct VFSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(VF.labelFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}
