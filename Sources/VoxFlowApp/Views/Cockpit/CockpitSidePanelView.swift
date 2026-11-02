import SwiftUI

/// Cockpit side panel: Target, Notion, Dictionary, Assistant and Recent
/// sections, each a sentence-case header over plain rows with separators.
///
/// Omits only the ambient-buffer status (Layer 2). Per-layer content per the
/// cockpit design spec.
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
            assistantSection
            recentSection
            Spacer()
        }
        .padding(VF.spacingMedium)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.thinMaterial)
    }

    /// The session's frozen target; with no session yet, the app the next
    /// recording will freeze.
    private var targetName: String? {
        if let session = sessionService.currentSession {
            return session.targetApp?.appName
        }
        return state.lastExternalApp?.name
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            VFSectionHeader(title: "Target")
            HStack(spacing: VF.spacingSmall) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(VF.colorInfo)
                    .accessibilityHidden(true)
                if let name = targetName {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(VF.labelFont)
                            .lineLimit(1)
                        Text("append at cursor")
                            .font(VF.captionFont)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Focused app")
                        .font(VF.captionFont)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var assistantSection: some View {
        if state.assistantHandoffEnabled {
            VStack(alignment: .leading, spacing: VF.spacingSmall) {
                VFSectionHeader(title: "Assistant")
                Button {
                    coordinator.requestAssistantHandoff()
                } label: {
                    Label("Send to Assistant…", systemImage: "paperplane")
                        .font(VF.captionFont)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Preview the transcript, then hand it to your configured agent CLI")
                .accessibilityLabel("Send transcript to assistant")
            }
        }
    }

    private var notionSection: some View {
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            HStack {
                VFSectionHeader(title: "Notion")
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
                    .accessibilityLabel("Clear Notion target")
                }
            }

            if let selected = coordinator.notionTarget {
                // Selected state: show the current target.
                HStack(spacing: VF.spacingSmall) {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(VF.colorExternal)
                        .accessibilityHidden(true)
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
            } else {
                // Search field
                HStack(spacing: VF.spacingSmall) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(VF.captionFont)
                        .accessibilityHidden(true)
                    TextField("Search pages…", text: $notionQuery)
                        .font(VF.captionFont)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            runSearch()
                        }
                    if notionSearchInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .padding(VF.spacingSmall)
                .vfSurface(.card, in: RoundedRectangle(cornerRadius: VF.cornerSmall, style: .continuous))

                if !notionResults.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(notionResults.enumerated()), id: \.element.id) { index, result in
                            if index > 0 { Divider() }
                            Button {
                                coordinator.selectNotionTarget(result)
                                notionResults = []
                                notionQuery = ""
                            } label: {
                                HStack(spacing: VF.spacingSmall) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(VF.colorExternal)
                                        .font(VF.captionFont)
                                        .accessibilityHidden(true)
                                    Text(result.title)
                                        .font(VF.captionFont)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, VF.spacingSmall)
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("Type to search your Notion pages. Add a Notion token in Settings first.")
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
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            VFSectionHeader(title: "Recent")
            if state.recentDictations.isEmpty {
                Text("No captures yet")
                    .font(VF.captionFont)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.recentDictations.prefix(3).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(entry.rawText.prefix(80)) + (entry.rawText.count > 80 ? "…" : ""))
                                .font(VF.captionFont)
                                .lineLimit(2)
                            Text(entry.timestamp, style: .relative)
                                .font(VF.microFont)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, VF.spacingSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var dictionarySection: some View {
        VStack(alignment: .leading, spacing: VF.spacingXSmall) {
            VFSectionHeader(title: "Dictionary")
            let recent = Array(dictionary.entries.suffix(3).reversed())
            if recent.isEmpty {
                Text("No learned terms").font(VF.captionFont).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        HStack(spacing: VF.spacingSmall) {
                            Text(entry.wrong).font(VF.microFont).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(VF.microFont).foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            Text(entry.right).font(VF.captionFont)
                            Spacer()
                        }
                        .padding(.vertical, VF.spacingSmall)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
