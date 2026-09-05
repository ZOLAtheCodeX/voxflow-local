import Foundation

enum SkillProfileFile {
    struct Document: Codable {
        var schemaVersion = 1
        var profiles: [SkillProfile]
        var activeProfileID: UUID? = nil
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", profiles, activeProfileID = "active_profile_id"
        }
    }

    static func decode(_ data: Data) throws -> Document {
        guard data.count <= 1_048_576 else { throw SkillProfileError.invalid("Skill profile files must be at most 1 MB.") }
        let document: Document
        do { document = try JSONDecoder().decode(Document.self, from: data) }
        catch { throw SkillProfileError.invalid("Choose a VoxFlow skill profile JSON file with schema_version and profiles.") }
        guard document.schemaVersion == 1 else { throw SkillProfileError.invalid("This skill profile format version is not supported.") }
        return try validated(document)
    }

    static func validated(_ document: Document) throws -> Document {
        guard document.profiles.count <= 50 else { throw SkillProfileError.invalid("At most 50 profiles are supported.") }
        var names = Set<String>()
        var ids = Set<UUID>()
        var result = document
        result.profiles = try document.profiles.map {
            let profile = try $0.validated()
            guard names.insert(profile.name.lowercased()).inserted, ids.insert(profile.id).inserted else {
                throw SkillProfileError.invalid("Each profile needs a distinct name and ID.")
            }
            return profile
        }
        guard result.activeProfileID == nil || result.profiles.contains(where: { $0.id == result.activeProfileID }) else {
            throw SkillProfileError.invalid("The active profile is missing from the file.")
        }
        return result
    }

    static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated(document))
        guard data.count <= 1_048_576 else { throw SkillProfileError.invalid("Skill profile files must be at most 1 MB.") }
        return data
    }
}

struct SkillImportSummary: Equatable {
    var additions = 0
    var duplicates = 0
    var conflicts = 0
}

@MainActor
final class SkillProfileStore: ObservableObject {
    @Published private(set) var profiles: [SkillProfile] = []
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var lastError: String?
    private(set) var activeMatcher: SpokenSkillMatcher?
    private let fileURL: URL
    private let writer: (Data, URL) throws -> Void
    private var loadFailed = false

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VoxFlow/skill-profiles.json")
    }

    init(fileURL: URL = defaultFileURL,
         writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.fileURL = fileURL
        self.writer = writer
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let document = try SkillProfileFile.decode(Data(contentsOf: fileURL))
                profiles = document.profiles
                activeProfileID = document.activeProfileID
                activeMatcher = document.profiles.first { $0.id == document.activeProfileID }.map(SpokenSkillMatcher.init)
            }
        } catch {
            loadFailed = true
            lastError = "Could not read skill-profiles.json. The original file was preserved. Restore it from a backup or move it aside, then reopen VoxFlow. \(error.localizedDescription)"
        }
    }

    var activeProfile: SkillProfile? { profiles.first { $0.id == activeProfileID } }

    private func commit(_ profiles: [SkillProfile], activeID: UUID?) -> Bool {
        guard !loadFailed else { return false }
        do {
            let document = try SkillProfileFile.validated(.init(profiles: profiles, activeProfileID: activeID))
            try writer(SkillProfileFile.encode(document), fileURL)
            activeMatcher = document.profiles.first { $0.id == document.activeProfileID }.map(SpokenSkillMatcher.init)
            self.profiles = document.profiles
            activeProfileID = document.activeProfileID
            lastError = nil
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    @discardableResult
    func activate(_ id: UUID?) -> Bool { commit(profiles, activeID: id) }

    @discardableResult
    func save(_ profile: SkillProfile) -> Bool {
        var next = profiles
        if let index = next.firstIndex(where: { $0.id == profile.id }) { next[index] = profile }
        else { next.append(profile) }
        return commit(next, activeID: activeProfileID)
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        commit(profiles.filter { $0.id != id }, activeID: activeProfileID == id ? nil : activeProfileID)
    }

    func exportData() throws -> Data {
        // Importing/sharing never turns shortcuts on in someone else's app.
        try SkillProfileFile.encode(.init(profiles: profiles))
    }

    func previewImport(_ incoming: [SkillProfile]) throws -> SkillImportSummary {
        try merged(incoming, replaceConflicts: false).summary
    }

    @discardableResult
    func importProfiles(_ incoming: [SkillProfile], replaceConflicts: Bool = false) -> Bool {
        do { return commit(try merged(incoming, replaceConflicts: replaceConflicts).profiles, activeID: activeProfileID) }
        catch { lastError = error.localizedDescription; return false }
    }

    private func merged(_ incoming: [SkillProfile], replaceConflicts: Bool) throws
        -> (profiles: [SkillProfile], summary: SkillImportSummary) {
        let imported = try SkillProfileFile.validated(.init(profiles: incoming)).profiles
        var next = profiles
        var summary = SkillImportSummary()
        for var profile in imported {
            if let index = next.firstIndex(where: { $0.name.lowercased() == profile.name.lowercased() }) {
                if next[index].hasSameContent(as: profile) { summary.duplicates += 1 }
                else {
                    summary.conflicts += 1
                    if replaceConflicts { profile.id = next[index].id; next[index] = profile }
                }
            } else {
                if next.contains(where: { $0.id == profile.id }) { profile.id = UUID() }
                next.append(profile)
                summary.additions += 1
            }
        }
        _ = try SkillProfileFile.validated(.init(profiles: next, activeProfileID: activeProfileID))
        return (next, summary)
    }
}
