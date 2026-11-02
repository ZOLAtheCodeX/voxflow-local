import SwiftUI

/// An inline notice with a symbol, a selectable message, an optional action
/// and an optional dismiss button. Kind sets the symbol and color; the symbol
/// means color is never the only signal.
struct VFBanner: View {
    enum Kind {
        case info
        case warning
        case error
    }

    let kind: Kind
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: VF.spacingSmall) {
            Image(systemName: symbol)
                .font(VF.captionEmphasizedFont)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(VF.captionFont)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(VF.captionEmphasizedFont)
                    .buttonStyle(.borderless)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(VF.captionEmphasizedFont)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(VF.spacingSmall)
        .background(VF.tintedBackground(tint), in: RoundedRectangle(cornerRadius: VF.cornerSmall, style: .continuous))
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: return VF.colorInfo
        case .warning: return VF.colorWarning
        case .error: return VF.colorError
        }
    }
}
