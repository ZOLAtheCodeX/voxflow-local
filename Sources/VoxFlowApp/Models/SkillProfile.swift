import Foundation

struct SpokenSkill: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var aliases: [String] = []
    var command: String

    enum CodingKeys: String, CodingKey { case id, name, aliases, command }
}

extension SpokenSkill {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        command = try c.decode(String.self, forKey: .command)
    }
}

struct SkillProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var applications: [String]
    var skills: [SpokenSkill]

    enum CodingKeys: String, CodingKey { case id, name, applications, skills }

    func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SkillProfileError.invalid("Give the profile a name of 1–80 characters.")
        }
        result.applications = Array(Set(applications.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })).sorted()
        guard !result.applications.isEmpty, result.applications.count <= 50,
              result.applications.allSatisfy({ !$0.isEmpty && $0.count <= 256 && $0.contains(".") &&
                  $0.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").inverted) == nil }) else {
            throw SkillProfileError.invalid("Choose at least one application for this profile.")
        }
        guard skills.count <= 1000 else { throw SkillProfileError.invalid("A profile supports at most 1,000 skills.") }
        var owners: [String: UUID] = [:]
        var ids = Set<UUID>()
        result.skills = try skills.map { skill in
            var skill = skill
            guard ids.insert(skill.id).inserted else { throw SkillProfileError.invalid("Duplicate skill IDs in the profile.") }
            guard let name = SpokenSkillRouter.normalizedPhrase(skill.name), name.count <= 128,
                  skill.aliases.count <= 20 else { throw SkillProfileError.invalid("Each skill needs a spoken name of at most 128 characters and at most 20 aliases.") }
            skill.name = name
            skill.aliases = try skill.aliases.map {
                guard let alias = SpokenSkillRouter.normalizedPhrase($0), alias.count <= 128 else {
                    throw SkillProfileError.invalid("Skill aliases cannot be empty or longer than 128 characters.")
                }
                return alias
            }
            skill.aliases = Array(Set(skill.aliases)).sorted()
            guard !skill.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  skill.command.count <= 1000,
                  !skill.command.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !skill.command.contains(where: \.isNewline) else {
                throw SkillProfileError.invalid("Commands must be one line, without control characters, and at most 1,000 characters.")
            }
            for phrase in SpokenSkillRouter.phrases(for: skill) {
                if let owner = owners[phrase], owner != skill.id {
                    throw SkillProfileError.invalid("Two skills match ‘\(phrase)’. Give them distinct names or aliases.")
                }
                owners[phrase] = skill.id
            }
            return skill
        }
        return result
    }

    /// Import equality ignores generated IDs, so a hand-written profile can be
    /// imported repeatedly without creating conflicts or duplicates.
    func hasSameContent(as other: Self) -> Bool {
        name.lowercased() == other.name.lowercased() && applications == other.applications &&
        skills.map { [$0.name, $0.command] + $0.aliases } == other.skills.map { [$0.name, $0.command] + $0.aliases }
    }
}

extension SkillProfile {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        applications = try c.decode([String].self, forKey: .applications)
        skills = try c.decode([SpokenSkill].self, forKey: .skills)
    }
}

enum SkillProfileError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

enum SpokenSkillRouter {
    static func normalizedPhrase(_ raw: String) -> String? {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !$0.properties.isWhitespace }) else { return nil }
        let phrase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:\"“”"))
            .lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return phrase.isEmpty ? nil : phrase
    }

    static func phrases(for skill: SpokenSkill) -> Set<String> {
        var phrases = Set<String>()
        for raw in [skill.name] + skill.aliases {
            guard let name = normalizedPhrase(raw) else { continue }
            phrases.insert(name)
            for prefix in ["use ", "use the ", "use my "] { phrases.insert(prefix + name + " skill") }
        }
        let withoutGreeting = phrases
        for phrase in withoutGreeting {
            for prefix in ["hey ", "hey, ", "hey: "] { phrases.insert(prefix + phrase) }
        }
        return phrases
    }

    static func resolve(_ raw: String, profile: SkillProfile?, targetBundleID: String?) -> SpokenSkill? {
        profile.flatMap { SpokenSkillMatcher(profile: $0).resolve(raw, targetBundleID: targetBundleID) }
    }
}

/// Prepared when configuration changes; a capture takes an immutable copy.
struct SpokenSkillMatcher: Sendable {
    let profile: SkillProfile
    private let matches: [String: SpokenSkill]

    init(profile: SkillProfile) {
        self.profile = profile
        var matches: [String: SpokenSkill] = [:]
        var ambiguous = Set<String>()
        for skill in profile.skills {
            for phrase in SpokenSkillRouter.phrases(for: skill) {
                if let prior = matches[phrase], prior.id != skill.id { ambiguous.insert(phrase) }
                matches[phrase] = skill
            }
        }
        for phrase in ambiguous { matches.removeValue(forKey: phrase) }
        self.matches = matches
    }

    func resolve(_ raw: String, targetBundleID: String?) -> SpokenSkill? {
        guard let targetBundleID, profile.applications.contains(targetBundleID),
              VoiceCommandRouter.parse(raw) == .none,
              let phrase = SpokenSkillRouter.normalizedPhrase(raw) else { return nil }
        return matches[phrase]
    }
}
