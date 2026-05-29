import SwiftUI

/// Cockpit ⌘K palette — surface every smart action regardless of chip MRU.
///
/// Filters by typed query; clicking a row dismisses the sheet and dispatches
/// the action through the cockpit coordinator. Layer 1 will probably grow
/// this surface with snippet expansions + workflow chains.
struct ActionPaletteView: View {
    let onActionTriggered: (SmartActionId) -> Void
    /// Phase E — workflow chains to surface below the actions. Optional with a
    /// default so existing call sites stay valid.
    var chains: [WorkflowChain] = []
    /// Dispatch a chain run. Optional so the palette is usable without chains.
    var onChainTriggered: ((WorkflowChain) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type an action…", text: $query)
                .textFieldStyle(.plain)
                .padding(VF.spacingMedium)
                .background(.thinMaterial)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredActions, id: \.self) { id in
                        Button {
                            dismiss()
                            onActionTriggered(id)
                        } label: {
                            HStack {
                                Text(id.label).font(VF.bodyFont)
                                Spacer()
                                Text(id.shortDescription)
                                    .font(VF.captionFont)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, VF.spacingMedium)
                            .padding(.vertical, VF.spacingSmall)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !filteredChains.isEmpty {
                        Text("Chains")
                            .font(VF.captionFont)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, VF.spacingMedium)
                            .padding(.top, VF.spacingSmall)
                        ForEach(filteredChains) { chain in
                            Button {
                                dismiss()
                                onChainTriggered?(chain)
                            } label: {
                                HStack {
                                    Text(chain.name).font(VF.bodyFont)
                                    Spacer()
                                    Text(chain.steps.map(\.summary).joined(separator: " → "))
                                        .font(VF.captionFont)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .padding(.horizontal, VF.spacingMedium)
                                .padding(.vertical, VF.spacingSmall)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: 440, height: 320)
    }

    private var filteredActions: [SmartActionId] {
        guard !query.isEmpty else { return SmartActionId.allCases }
        return SmartActionId.allCases.filter {
            $0.label.localizedCaseInsensitiveContains(query) ||
            $0.shortDescription.localizedCaseInsensitiveContains(query)
        }
    }

    private var filteredChains: [WorkflowChain] {
        guard !query.isEmpty else { return chains }
        return chains.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
