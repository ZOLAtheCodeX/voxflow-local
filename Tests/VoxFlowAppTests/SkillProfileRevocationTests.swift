import Combine
import XCTest
@testable import VoxFlowApp

/// Calls AppCoordinator's subscription helper directly using real store commits
/// and the real text coordinator; does not cover the initializer installing it.
/// Never instantiate AppCoordinator.shared or native audio/AX services.
/// Every possible clipboard fallback is a spy.
@MainActor
final class SkillProfileRevocationTests: XCTestCase {
    func testEveryActiveProfileMutationRevokesTheOriginalCaptureWithoutProseFallback() async throws {
        for change in ["off", "remove", "switch", "command", "alias", "applications", "remove-skill", "import"] {
            let h = try Harness()
            h.capture()
            var edited = h.profile
            switch change {
            case "off": XCTAssertTrue(h.store.activate(nil))
            case "remove": XCTAssertTrue(h.store.remove(h.profile.id))
            case "switch": XCTAssertTrue(h.store.activate(h.other.id))
            case "command":
                edited.skills[0].command = "/changed"
                XCTAssertTrue(h.store.save(edited))
            case "alias":
                edited.skills[0].aliases = []
                XCTAssertTrue(h.store.save(edited))
            case "applications":
                edited.applications = ["com.microsoft.VSCode"]
                XCTAssertTrue(h.store.save(edited))
            case "remove-skill":
                edited.skills = []
                XCTAssertTrue(h.store.save(edited))
            default:
                edited.skills[0].command = "/imported"
                XCTAssertTrue(h.store.importProfiles([edited], replaceConflicts: true))
            }
            XCTAssertTrue(try XCTUnwrap(h.permission).revoked, change)
            XCTAssertEqual(h.submissionRevocations, 1, change)
            // The original matcher MUST remain usable for classification. Losing
            // it would downgrade old audio into ordinary dictation after Off.
            let skill = try XCTUnwrap(h.matcher?.resolve("research", targetBundleID: "com.apple.Terminal"))
            XCTAssertEqual(skill.command, "/research", change)
            for mode in AutoSubmitMode.allCases {
                let success = await h.insertion.insertText(skill.command, statusSuffix: "Skill inserted", targetApp: nil,
                    timing: nil, policy: .verbatim.withSubmission(mode.includes(voiceActionPrompt: true))
                        .withVoiceActionPermission(h.permission))
                XCTAssertFalse(success, "\(change), \(mode)")
            }
            XCTAssertEqual(h.service.calls, 0, change)
            XCTAssertTrue(h.clipboardCopies.isEmpty, change)
            XCTAssertFalse(FileManager.default.fileExists(atPath: h.auditURL.path), change)
        }
    }

    func testSubscriptionIgnoresInitialEmissionNoOpsAndInactiveProfileChanges() throws {
        let h = try Harness()
        h.capture()
        // Attaching to an already active profile must not revoke a capture.
        h.attachObserver()
        XCTAssertFalse(try XCTUnwrap(h.permission).revoked)
        XCTAssertTrue(h.store.activate(h.profile.id))
        XCTAssertTrue(h.store.save(h.profile))
        var inactive = h.other
        inactive.skills[0].command = "/inactive-edit"
        XCTAssertTrue(h.store.save(inactive))
        XCTAssertTrue(h.store.remove(inactive.id))
        var conflict = h.profile
        conflict.skills[0].command = "/not-approved"
        XCTAssertTrue(h.store.importProfiles([conflict], replaceConflicts: false))
        XCTAssertFalse(try XCTUnwrap(h.permission).revoked)
        XCTAssertEqual(h.submissionRevocations, 0)
    }

    func testFailedSaveOrInvalidChangeDoesNotWithdrawValidCapture() throws {
        let h = try Harness()
        h.capture()
        let diskBefore = try Data(contentsOf: h.storeURL)
        h.writes.fail = true
        XCTAssertFalse(h.store.activate(nil))
        XCTAssertFalse(h.store.remove(h.profile.id))
        var changed = h.profile
        changed.skills[0].command = "/new"
        XCTAssertFalse(h.store.save(changed))
        XCTAssertFalse(h.store.importProfiles([changed], replaceConflicts: true))
        h.writes.fail = false
        changed.skills[0].command = "bad\ncommand"
        XCTAssertFalse(h.store.save(changed))
        XCTAssertEqual(try Data(contentsOf: h.storeURL), diskBefore)
        XCTAssertFalse(try XCTUnwrap(h.permission).revoked)
        XCTAssertEqual(h.submissionRevocations, 0)
        XCTAssertEqual(h.store.activeProfileID, h.profile.id)
    }

    func testRevocationDuringInsertionWaitNeverCopiesTheWithheldCommand() async throws {
        let h = try Harness()
        h.capture()
        h.service.onInsert = { [unowned h] _ in
            XCTAssertTrue(h.store.activate(nil))
            await Task.yield()
            return InsertResult(method: .failed, success: false, fallbackUsed: false, errorCode: "TARGET_CHANGED")
        }
        let result = await h.insertion.insertText("/research", statusSuffix: "Skill inserted", targetApp: nil,
            timing: nil, policy: .verbatim.withSubmission(true).withVoiceActionPermission(h.permission))
        XCTAssertFalse(result)
        XCTAssertEqual(h.service.calls, 1)
        XCTAssertTrue(try XCTUnwrap(h.permission).revoked)
        XCTAssertTrue(h.clipboardCopies.isEmpty)
        XCTAssertEqual(h.state.failedInsertCount, 0)
        XCTAssertNil(h.state.lastInsertResult)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.auditURL.path))
    }

    func testAlreadyPostedTextKeepsReceiptWithoutRetryAfterRevocation() async throws {
        let h = try Harness()
        h.capture()
        h.service.onInsert = { [unowned h] _ in
            XCTAssertTrue(h.store.activate(nil))
            return InsertResult(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil, submission: .skipped)
        }
        let success = await h.insertion.insertText("/research", statusSuffix: "Skill inserted", targetApp: nil,
            timing: nil, policy: .verbatim.withSubmission(true).withVoiceActionPermission(h.permission))
        XCTAssertTrue(success)
        XCTAssertEqual(h.service.calls, 1)
        XCTAssertTrue(h.clipboardCopies.isEmpty)
        let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: h.auditURL)) as? [String: Any])
        XCTAssertEqual(row["submission"] as? String, "skipped")
        XCTAssertEqual(row["text"] as? String, "/research")
    }

    func testOrdinaryInsertionFailureStillOffersItsExistingRecoveryCopy() async throws {
        let h = try Harness()
        h.service.onInsert = { _ in .init(method: .failed, success: false, fallbackUsed: false, errorCode: "UNAVAILABLE") }
        let success = await h.insertion.insertText("Ordinary text", statusSuffix: "Inserted", targetApp: nil,
            timing: nil, policy: .prose)
        XCTAssertFalse(success)
        XCTAssertEqual(h.clipboardCopies, ["Ordinary text"])
        XCTAssertEqual(h.state.failedInsertCount, 1)
    }

    func testOldAudioCannotAcquireNewMappingsAndNewCapturesRemainUsable() throws {
        let h = try Harness()
        XCTAssertTrue(h.store.activate(nil))
        h.capture()
        XCTAssertNil(h.matcher)
        XCTAssertTrue(h.store.activate(h.profile.id))
        XCTAssertNil(h.matcher)
        XCTAssertTrue(try XCTUnwrap(h.permission).revoked)
        h.capture()
        XCTAssertFalse(try XCTUnwrap(h.permission).revoked)
        XCTAssertEqual(h.matcher?.resolve("research", targetBundleID: "com.apple.Terminal")?.command, "/research")
        // Callback reads the current capture, not the one that existed at binding.
        XCTAssertTrue(h.store.activate(nil))
        XCTAssertTrue(try XCTUnwrap(h.permission).revoked)
    }

    func testProfileChangesDoNotRevokeBuiltInOnlyCaptures() throws {
        let h = try Harness()
        h.capture(mode: .computerActions)
        XCTAssertTrue(h.store.activate(nil))
        XCTAssertFalse(try XCTUnwrap(h.permission).revoked)
        XCTAssertEqual(h.submissionRevocations, 0)
    }

    private final class WriteControl { var fail = false }
    private final class InsertFake: TextInserting {
        var calls = 0
        var onInsert: (TextInsertionPolicy) async -> InsertResult = { _ in
            .init(method: .simulatedPaste, success: true, fallbackUsed: true, errorCode: nil)
        }
        func insert(text: String, targetApp: NSRunningApplication?) async -> InsertResult {
            await insert(text: text, targetApp: targetApp, policy: .prose)
        }
        func insert(text: String, targetApp: NSRunningApplication?, policy: TextInsertionPolicy) async -> InsertResult {
            calls += 1
            return await onInsert(policy)
        }
    }
    @MainActor
    private final class Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-revocation-\(UUID())")
        let profile = SkillProfile(name: "QA CLI", applications: ["com.apple.Terminal", "com.microsoft.VSCode"],
            skills: [.init(name: "research", aliases: ["deep research"], command: "/research")])
        let other = SkillProfile(name: "Other CLI", applications: ["com.apple.Terminal"],
            skills: [.init(name: "other", aliases: [], command: "/other")])
        let store: SkillProfileStore
        let writes = WriteControl()
        let service = InsertFake()
        let state = AppState()
        var matcher: SpokenSkillMatcher?
        var permission: CapturedVoiceActions?
        var submissionRevocations = 0
        var clipboardCopies: [String] = []
        var observer: AnyCancellable?
        var storeURL: URL { directory.appendingPathComponent("profiles.json") }
        var auditURL: URL { directory.appendingPathComponent("receipts.jsonl") }
        lazy var insertion = TextInsertionCoordinator(state: state, insertService: service,
            audit: InsertionAuditLog(fileURL: auditURL), copyFailedInsertion: { [weak self] in self?.clipboardCopies.append($0) })

        init() throws {
            let writes = writes
            store = SkillProfileStore(fileURL: directory.appendingPathComponent("profiles.json"), writer: { data, url in
                if writes.fail { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            XCTAssertTrue(store.save(profile))
            XCTAssertTrue(store.save(other))
            XCTAssertTrue(store.activate(profile.id))
            attachObserver()
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func capture(mode: VoiceActionMode = .all) {
            matcher = mode.includesCustomPrompts ? store.activeMatcher : nil
            permission = CapturedVoiceActions(mode: mode, enabledIDs: [], requiresPrefix: false)
        }
        func attachObserver() {
            observer = AppCoordinator.observeSkillProfileChanges(in: store,
                capturedPermission: { [weak self] in self?.permission },
                revokeSubmission: { [weak self] in self?.submissionRevocations += 1 })
        }
    }
}
