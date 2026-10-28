import SwiftUI
import UniformTypeIdentifiers

struct VocabularySettingsSection: View {
    @ObservedObject var dictionary: DictionaryStore
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var showingEditor = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ConfigurationDocument()
    @State private var pending: VocabularyImport?
    @State private var message: String?

    private struct VocabularyImport: Identifiable {
        let id = UUID()
        let items: [VocabularyItem]
        let summary: VocabularyImportSummary
        let details: [String]
    }

    private var filtered: [DictionaryEntry] {
        dictionary.entries.filter { query.isEmpty || $0.right.localizedCaseInsensitiveContains(query) || $0.wrong.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Section("Vocabulary") {
            HStack {
                Text("\(dictionary.entries.count) entries").font(VF.labelFont)
                Spacer()
                Button("Add term") { editing = nil; showingEditor = true }
                Button("Import…") { importing = true }
                Button("Export…") {
                    do { exportDocument = ConfigurationDocument(data: try dictionary.exportData()); exporting = true }
                    catch { message = error.localizedDescription }
                }
            }
            TextField("Find a term or spoken form", text: $query)
            if dictionary.entries.isEmpty {
                Text("Add preferred spellings or import a text list. Spoken forms are optional.")
                    .font(VF.captionFont).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: VF.spacingSmall) {
                        ForEach(filtered) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.right).font(VF.bodyFont)
                                    if !entry.wrong.isEmpty { Text("Heard as: \(entry.wrong)").font(VF.captionFont).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button { dictionary.setPrioritized(entry.id, entry.prioritized != true) } label: {
                                    Image(systemName: entry.prioritized == true ? "pin.fill" : "pin")
                                }.help("Prioritize this spelling in recognition hints")
                                    .accessibilityLabel("\(entry.prioritized == true ? "Unpin" : "Prioritize") \(entry.right)")
                                Button { editing = entry; showingEditor = true } label: { Image(systemName: "pencil") }
                                    .accessibilityLabel("Edit \(entry.right)")
                                Button(role: .destructive) { dictionary.remove(entry.id) } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("Remove \(entry.right)")
                            }.buttonStyle(.borderless)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 250)
            }
            let hints = VocabularyBiasing.terms(from: dictionary.entries).prefix(VocabularyBiasing.maxTerms)
            Text("Recognition considers up to 24 spellings, with a 100-token limit. Pinned terms come first; corrections use the full dictionary.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            if !hints.isEmpty {
                DisclosureGroup("Recognition shortlist") {
                    Text(hints.joined(separator: ", ")).font(VF.captionFont).textSelection(.enabled)
                    Text("Long spellings may reach the token limit before the end of this list.")
                        .font(VF.captionFont).foregroundStyle(.secondary)
                }
            }
            if let error = dictionary.lastError ?? message { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
        }
        .sheet(isPresented: $showingEditor) {
            VocabularyEntryEditor(entry: editing) { spoken, written, prioritized in
                let success: Bool
                if let editing { success = dictionary.update(id: editing.id, spoken: spoken, written: written, prioritized: prioritized) }
                else { success = dictionary.add(wrong: spoken, right: written, context: "manual", prioritized: prioritized) }
                return success ? nil : (dictionary.lastError ?? "The vocabulary entry could not be saved.")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText]) { result in
            do {
                let url = try result.get()
                let items = try VocabularyFile.decode(ConfigurationFileAccess.read(url), isJSON: url.pathExtension.lowercased() == "json")
                let summary = try dictionary.previewImport(items)
                let details = items.map { item in
                    let existing = dictionary.entries.first { DictionaryStore.item(for: $0).key == item.key }
                    let source = item.spoken.map { "\($0) → " } ?? ""
                    return source + item.written + (existing.map { "\nExisting: \($0.right)" } ?? "\nNew entry")
                }
                pending = VocabularyImport(items: items, summary: summary, details: details)
                message = nil
            } catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "voxflow-vocabulary") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .sheet(item: $pending) { item in
            ConfigurationImportReview(title: "Import vocabulary", additions: item.summary.additions,
                duplicates: item.summary.duplicates, conflicts: item.summary.conflicts, details: item.details) { replace in
                dictionary.importItems(item.items, replaceConflicts: replace) ? nil : (dictionary.lastError ?? "Import failed.")
            }
        }
    }
}

private struct VocabularyEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var spoken: String
    @State private var written: String
    @State private var prioritized: Bool
    @State private var error: String?
    let save: (String, String, Bool) -> String?

    init(entry: DictionaryEntry?, save: @escaping (String, String, Bool) -> String?) {
        _spoken = State(initialValue: entry?.wrong ?? "")
        _written = State(initialValue: entry?.right ?? "")
        _prioritized = State(initialValue: entry?.prioritized == true)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text("Vocabulary entry").font(VF.titleFont)
            TextField("Preferred spelling", text: $written)
            TextField("Spoken or misrecognized form (optional)", text: $spoken)
            Toggle("Prioritize in recognition hints", isOn: $prioritized)
            if let error { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") {
                    if let message = save(spoken, written, prioritized) { error = message } else { dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(written.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(VF.spacingLarge).frame(width: 440)
    }
}
