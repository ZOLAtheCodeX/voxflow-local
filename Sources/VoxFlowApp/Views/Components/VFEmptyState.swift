import SwiftUI

/// One shortcut shown under an empty state, such as "⌘R" and "Start recording".
struct VFShortcutHint: Hashable {
    let keys: String
    let label: String
}

/// What a surface shows when there is nothing to list yet: what is missing,
/// why, and which shortcuts to use.
struct VFEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var shortcuts: [VFShortcutHint] = []

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
                .font(VF.headingFont)
        } description: {
            Text(message)
                .font(VF.captionFont)
        } actions: {
            if !shortcuts.isEmpty {
                VStack(alignment: .leading, spacing: VF.spacingXSmall) {
                    ForEach(shortcuts, id: \.self) { hint in
                        HStack(spacing: VF.spacingSmall) {
                            VFKeycap(keys: hint.keys)
                            Text(hint.label)
                                .font(VF.captionFont)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
