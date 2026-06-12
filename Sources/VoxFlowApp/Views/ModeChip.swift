import SwiftUI

struct ModeChip: View {
    let mode: CleanupMode
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(mode.displayName)
                .font(VF.labelFont)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(mode.displayName) cleanup mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
