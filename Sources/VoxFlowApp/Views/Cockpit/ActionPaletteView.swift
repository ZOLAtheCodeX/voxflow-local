import SwiftUI

/// R4.4: selection state for the keyboard-first palette. Wraps at both
/// ends; filtering that shrinks the list resets an out-of-range selection.
struct PaletteSelectionModel {
    private(set) var selectedIndex: Int = 0
    private var count: Int

    init(count: Int) {
        self.count = count
    }

    mutating func move(_ delta: Int) {
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    mutating func updateCount(_ newCount: Int) {
        count = newCount
        if selectedIndex >= newCount {
            selectedIndex = 0
        }
    }
}

/// Cockpit ⌘K palette — every smart action plus workflow chains, keyboard
/// first (R4.4): type to filter, ↑↓ to select, ⏎ to run, esc to close.
/// Presented as a floating overlay card (spotlight idiom), not a sheet —
/// macOS sheets slide from the window chrome and read as modal dialogs.
struct ActionPaletteView: View {
    let onActionTriggered: (SmartActionId) -> Void
    var chains: [WorkflowChain] = []
    var onChainTriggered: ((WorkflowChain) -> Void)? = nil
    var onDismiss: () -> Void = {}

    @State private var query: String = ""
    @State private var selection = PaletteSelectionModel(count: SmartActionId.allCases.count)
    @FocusState private var queryFocused: Bool

    private enum PaletteItem: Identifiable {
        case action(SmartActionId)
        case chain(WorkflowChain)

        var id: String {
            switch self {
            case .action(let a): return "action-\(a.rawValue)"
            case .chain(let c): return "chain-\(c.id)"
            }
        }
    }

    private var items: [PaletteItem] {
        let actions = filteredActions.map(PaletteItem.action)
        let chainItems = filteredChains.map(PaletteItem.chain)
        return actions + chainItems
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Type an action…", text: $query)
                .textFieldStyle(.plain)
                .padding(VF.spacingMedium)
                .background(.thinMaterial)
                .focused($queryFocused)
                .onKeyPress(.downArrow) { selection.move(1); return .handled }
                .onKeyPress(.upArrow) { selection.move(-1); return .handled }
                .onKeyPress(.return) { runSelected(); return .handled }
                .onKeyPress(.escape) { onDismiss(); return .handled }
                .accessibilityLabel("Search actions and chains")

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(for: item, isSelected: index == selection.selectedIndex)
                                .id(index)
                        }
                        if items.isEmpty {
                            Text("No matches")
                                .font(VF.captionFont)
                                .foregroundStyle(.secondary)
                                .padding(VF.spacingMedium)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: selection.selectedIndex) { _, newIndex in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 440, height: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VF.cornerLarge, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .onAppear { queryFocused = true }
        .onChange(of: query) { _, _ in selection.updateCount(items.count) }
        .onChange(of: chains.count) { _, _ in selection.updateCount(items.count) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Action palette")
    }

    @ViewBuilder
    private func row(for item: PaletteItem, isSelected: Bool) -> some View {
        Button {
            run(item)
        } label: {
            HStack {
                switch item {
                case .action(let id):
                    Text(id.label).font(VF.bodyFont)
                    Spacer()
                    Text(id.shortDescription)
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                case .chain(let chain):
                    Image(systemName: "link").font(VF.captionFont).foregroundStyle(.secondary)
                    Text(chain.name).font(VF.bodyFont)
                    Spacer()
                    Text(chain.steps.map(\.summary).joined(separator: " → "))
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, VF.spacingMedium)
            .padding(.vertical, VF.spacingSmall)
            .contentShape(Rectangle())
            .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func runSelected() {
        guard items.indices.contains(selection.selectedIndex) else { return }
        run(items[selection.selectedIndex])
    }

    private func run(_ item: PaletteItem) {
        onDismiss()
        switch item {
        case .action(let id): onActionTriggered(id)
        case .chain(let chain): onChainTriggered?(chain)
        }
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
