import SwiftUI

/// Cockpit side panel — Target + Notion + Recent cards.
///
/// Layer 0 omits the Dictionary card (Layer 1) and the ambient-buffer
/// status (Layer 2). Per-layer content per the cockpit design spec.
struct CockpitSidePanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var sessionService: LongFormSessionService
    @ObservedObject var dictionary: DictionaryStore
    @ObservedObject var coordinator: CockpitCoordinator

    @State private var notionQuery: String = ""
    @State private var notionResults: [NotionTarget] = []
    @State private var notionSearchInProgress: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingLarge) {
            targetSection
            notionSection
            dictionarySection
            recentSection
            Spacer()
        }
        .padding(VF.spacingMedium)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Target")
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(VF.colorInfo)
                if let target = sessionService.currentSession?.targetApp,
                   let name = target.appName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(VF.labelFont)
                        Text("append at cursor")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("focused app")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(VF.spacingSmall)
            .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
        }
    }

    private var notionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("Notion")
                if coordinator.notionTarget != nil {
                    Spacer()
                    Button {
                        coordinator.selectNotionTarget(nil)
                        notionResults = []
                        notionQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear Notion target")
                }
            }

            if let selected = coordinator.notionTarget {
                // Selected state — show current target
                HStack(spacing: VF.spacingSmall) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(VF.colorExternal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notion · \(selected.title)")
                            .font(VF.labelFont)
                            .lineLimit(1)
                        Text("append on ⌘↩")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(VF.spacingSmall)
                .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
            } else {
                // Search field
                HStack(spacing: VF.spacingSmall) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(VF.captionFont)
                    TextField("Search pages…", text: $notionQuery)
                        .font(VF.captionFont)
                        .onSubmit {
                            runSearch()
                        }
                    if notionSearchInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(VF.spacingSmall)
                .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))

                if !notionResults.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notionResults) { result in
                            Button {
                                coordinator.selectNotionTarget(result)
                                notionResults = []
                                notionQuery = ""
                            } label: {
                                HStack(spacing: VF.spacingSmall) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(VF.colorExternal)
                                        .font(VF.captionFont)
                                    Text(result.title)
                                        .font(VF.captionFont)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(VF.spacingSmall)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let err = coordinator.notionSearchError {
                    Text(err)
                        .font(VF.microFont)
                        .foregroundStyle(VF.colorExternal)
                        .fixedSize(horizontal: false, vertical: true)
                } else if notionQuery.isEmpty {
                    Text("Type to search your Notion pages. Token required — set in Settings.")
                        .font(VF.microFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func runSearch() {
        let query = notionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        notionSearchInProgress = true
        Task {
            let results = await coordinator.searchNotion(query)
            await MainActor.run {
                notionResults = results
                notionSearchInProgress = false
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Recent")
            if state.recentDictations.isEmpty {
                Text("No captures yet")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.recentDictations.prefix(3), id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(entry.rawText.prefix(80)) + (entry.rawText.count > 80 ? "…" : ""))
                            .font(VF.captionFont)
                            .lineLimit(2)
                        Text(entry.timestamp, style: .relative)
                            .font(VF.microFont)
                            .foregroundStyle(.secondary)
                    }
                    .padding(VF.spacingSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
                }
            }
        }
    }

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Dictionary")
            let recent = Array(dictionary.entries.suffix(3).reversed())
            if recent.isEmpty {
                Text("No learned terms").font(VF.captionFont).foregroundStyle(.secondary)
            } else {
                ForEach(recent) { entry in
                    HStack(spacing: VF.spacingSmall) {
                        Text(entry.wrong).font(VF.microFont).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                        Text(entry.right).font(VF.captionFont)
                        Spacer()
                    }
                    .padding(VF.spacingSmall)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(VF.cardBackground, in: RoundedRectangle(cornerRadius: VF.cornerSmall))
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(VF.captionEmphasizedFont)
            .tracking(1)
            .foregroundStyle(.secondary)
    }
}
