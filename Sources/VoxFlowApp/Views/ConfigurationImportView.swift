import SwiftUI
import UniformTypeIdentifiers

struct ConfigurationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ConfigurationFileAccess {
    static func read(_ url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 1_048_576 else { throw VocabularyFileError.tooLarge }
        return data
    }
}

struct ConfigurationImportReview: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let additions: Int
    let duplicates: Int
    let conflicts: Int
    let details: [String]
    /// nil means the transaction succeeded; otherwise keep the sheet open.
    let apply: (Bool) -> String?
    @State private var replaceConflicts = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VF.spacingMedium) {
            Text(title).font(VF.titleFont)
            Text("\(additions) additions · \(duplicates) duplicates skipped · \(conflicts) conflicts")
                .font(VF.bodyFont)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VF.spacingSmall) {
                    ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                        Text(detail).font(VF.bodyFont).textSelection(.enabled)
                        Divider()
                    }
                }
            }.frame(maxHeight: 280)
            Toggle("Replace conflicting existing entries", isOn: $replaceConflicts)
                .disabled(conflicts == 0)
            Text("Existing entries are kept unless replacement is selected.")
                .font(VF.captionFont).foregroundStyle(.secondary)
            if let error { Text(error).font(VF.captionFont).foregroundStyle(VF.colorError) }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Import") {
                    if let message = apply(replaceConflicts) { error = message } else { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(VF.spacingLarge).frame(width: 520)
    }
}
