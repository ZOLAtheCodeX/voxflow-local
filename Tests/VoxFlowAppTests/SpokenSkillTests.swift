import XCTest
@testable import VoxFlowApp

final class SpokenSkillTests: XCTestCase {
    private func profile(command: String = "/research") -> SkillProfile {
        SkillProfile(name: "My CLI", applications: ["com.apple.Terminal"],
                     skills: [SpokenSkill(name: "research", aliases: ["deep research"], command: command)])
    }

    func testCompleteInvocationsResolveWithExactConfiguredSyntax() throws {
        for command in ["/research", "$research", "/my:research --local"] {
            let matcher = SpokenSkillMatcher(profile: try profile(command: command).validated())
            for phrase in ["research", "Deep Research!", "Use the research skill.",
                           "Hey, use my research skill!", "hey use deep research skill",
                           "  HEY:   use  the research skill.  "] {
                XCTAssertEqual(matcher.resolve(phrase, targetBundleID: "com.apple.Terminal")?.command, command, phrase)
            }
        }
    }

    func testProseUnknownNamesAndUnconfiguredApplicationsDoNotExpand() {
        let matcher = SpokenSkillMatcher(profile: profile())
        for phrase in ["Please use the research skill when you review this.",
                       "I want to do deep research", "use the missing skill", "research tomorrow", "cancel", "memo"] {
            XCTAssertNil(matcher.resolve(phrase, targetBundleID: "com.apple.Terminal"), phrase)
        }
        XCTAssertNil(matcher.resolve("research", targetBundleID: "com.apple.TextEdit"))
        XCTAssertNil(matcher.resolve("research", targetBundleID: nil))
        XCTAssertNil(SpokenSkillRouter.resolve("research", profile: nil, targetBundleID: "com.apple.Terminal"))
        XCTAssertEqual(VoiceCommandRouter.parse("use the research skill"), .none)
        XCTAssertEqual(VoiceCommandRouter.parse("undo"), .undo)
    }

    func testAmbiguousAliasesAndGreetingCollisionsFailValidationAndRuntimeLookup() {
        var profile = profile()
        profile.skills.append(SpokenSkill(name: "another", aliases: ["DEEP RESEARCH"], command: "/another"))
        XCTAssertThrowsError(try profile.validated())
        XCTAssertNil(SpokenSkillMatcher(profile: profile).resolve("deep research", targetBundleID: "com.apple.Terminal"))
        profile.skills[1].aliases = ["hey research"]
        XCTAssertThrowsError(try profile.validated())
    }

    func testCommandDefinitionsCannotContainImplicitSubmissionOrControlCharacters() {
        for command in ["/research\n", "/research\r", "first\nsecond", "/research\u{1b}[0m", "\t/research", "/research\u{2028}other", " "] {
            XCTAssertThrowsError(try profile(command: command).validated(), command.debugDescription)
        }
    }

    func testConfiguredReservedNamesDoNotOverrideCockpitWords() throws {
        let reserved = SkillProfile(name: "Reserved names", applications: ["com.apple.Terminal"],
                                    skills: [SpokenSkill(name: "undo", command: "/undo-skill")])
        let matcher = SpokenSkillMatcher(profile: try reserved.validated())
        XCTAssertNil(matcher.resolve("undo", targetBundleID: "com.apple.Terminal"))
        XCTAssertEqual(matcher.resolve("use the undo skill", targetBundleID: "com.apple.Terminal")?.command, "/undo-skill")
        XCTAssertEqual(VoiceCommandRouter.parse("undo"), .undo)
    }

    @MainActor
    func testHandWrittenImportRoundTripStaysOffAndCaptureSnapshotIsStable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profiles.json")
        let json = """
        {"schema_version":1,"profiles":[{"name":"My CLI","applications":["com.apple.Terminal"],"skills":[{"name":"research","command":"/research"}]}]}
        """
        let incoming = try SkillProfileFile.decode(Data(json.utf8)).profiles
        let store = SkillProfileStore(fileURL: url)
        XCTAssertTrue(store.importProfiles(incoming))
        XCTAssertNil(store.activeProfileID)
        XCTAssertNil(store.activeMatcher)
        XCTAssertEqual(try store.previewImport(SkillProfileFile.decode(Data(json.utf8)).profiles).duplicates, 1)
        let id = try XCTUnwrap(store.profiles.first?.id)
        XCTAssertTrue(store.activate(id))
        let captured = try XCTUnwrap(store.activeMatcher)
        var edited = try XCTUnwrap(store.activeProfile)
        edited.skills[0].command = "/changed"
        XCTAssertTrue(store.save(edited))
        XCTAssertEqual(captured.resolve("research", targetBundleID: "com.apple.Terminal")?.command, "/research")
        XCTAssertEqual(store.activeMatcher?.resolve("research", targetBundleID: "com.apple.Terminal")?.command, "/changed")
        XCTAssertNil(try SkillProfileFile.decode(store.exportData()).activeProfileID)
        XCTAssertEqual(SkillProfileStore(fileURL: url).activeProfileID, id)
        XCTAssertTrue(store.activate(nil))
        XCTAssertNil(store.activeMatcher)
        XCTAssertNil(SkillProfileStore(fileURL: url).activeProfileID)
    }

    @MainActor
    func testConflictingImportPreservesActiveIdentityAndRequiresExplicitReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SkillProfileStore(fileURL: url)
        let first = profile()
        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.activate(first.id))
        let second = profile(command: "$research")
        XCTAssertEqual(try store.previewImport([second]).conflicts, 1)
        XCTAssertTrue(store.importProfiles([second]))
        XCTAssertEqual(store.activeProfile?.skills.first?.command, "/research")
        XCTAssertTrue(store.importProfiles([second], replaceConflicts: true))
        XCTAssertEqual(store.activeProfileID, first.id)
        XCTAssertEqual(store.activeProfile?.skills.first?.command, "$research")
        XCTAssertTrue(store.remove(first.id))
        XCTAssertNil(store.activeMatcher)
    }

    @MainActor
    func testFailedSaveAndCorruptFilesNeverLoseUsableState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skills-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let initial = SkillProfileStore(fileURL: url)
        let p = profile()
        XCTAssertTrue(initial.save(p))
        let before = try Data(contentsOf: url)
        let failing = SkillProfileStore(fileURL: url, writer: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertFalse(failing.activate(p.id))
        XCTAssertNil(failing.activeMatcher)
        XCTAssertEqual(try Data(contentsOf: url), before)
        let corrupt = Data("{unfinished".utf8)
        try corrupt.write(to: url)
        let broken = SkillProfileStore(fileURL: url)
        XCTAssertNotNil(broken.lastError)
        XCTAssertFalse(broken.save(p))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertThrowsError(try SkillProfileFile.decode(Data("{\"schema_version\":2,\"profiles\":[]}".utf8)))
    }
}
