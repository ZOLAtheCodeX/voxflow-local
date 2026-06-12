import XCTest
@testable import VoxFlowApp

@MainActor
final class ChainStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
    }

    // MARK: - add()

    func test_add_persists_and_reloads() {
        let url = tmpURL()
        let store = ChainStore(fileURL: url, seedOnFirstRun: false)
        let steps: [ChainStep] = [.action(actionId: .memo), .insert(targetHint: nil)]
        XCTAssertTrue(store.add(name: "Memo Flow", steps: steps))

        let reloaded = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.chains.count, 1)
        XCTAssertEqual(reloaded.chains.first?.name, "Memo Flow")
        XCTAssertEqual(reloaded.chains.first?.steps, steps)
    }

    func test_add_rejects_empty_name() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(name: "", steps: [.action(actionId: .memo)]))
        XCTAssertTrue(store.chains.isEmpty)
    }

    func test_add_rejects_whitespace_name() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(name: "   ", steps: [.action(actionId: .memo)]))
        XCTAssertTrue(store.chains.isEmpty)
    }

    func test_add_rejects_empty_steps() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertFalse(store.add(name: "X", steps: []))
        XCTAssertTrue(store.chains.isEmpty)
    }

    func test_add_rejects_duplicate_normalized_name() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        // Different case must normalize to the same name and be rejected.
        XCTAssertFalse(store.add(name: "memo flow", steps: [.action(actionId: .mece)]))
        XCTAssertEqual(store.chains.count, 1)
    }

    // MARK: - remove()

    func test_remove_deletes_by_id() {
        let url = tmpURL()
        let store = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        let id = store.chains[0].id
        store.remove(id)
        XCTAssertTrue(store.chains.isEmpty)

        let reloaded = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(reloaded.chains.isEmpty)
    }

    // MARK: - update()

    func test_update_changes_fields_preserves_id_and_createdAt() {
        let url = tmpURL()
        let store = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        let id = store.chains[0].id
        let createdAt = store.chains[0].createdAt

        let newSteps: [ChainStep] = [.action(actionId: .items)]
        XCTAssertTrue(store.update(id: id, name: "New", steps: newSteps))
        XCTAssertEqual(store.chains.count, 1)
        XCTAssertEqual(store.chains[0].id, id)
        XCTAssertEqual(store.chains[0].createdAt, createdAt)
        XCTAssertEqual(store.chains[0].name, "New")
        XCTAssertEqual(store.chains[0].steps, newSteps)

        // Reload from disk: confirms createdAt round-trips through `.iso8601`
        // (floored to whole seconds), and the in-memory createdAt equals the
        // reloaded one. This is the critical regression guard.
        let reloaded = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertEqual(reloaded.chains.count, 1)
        XCTAssertEqual(reloaded.chains[0].id, id)
        XCTAssertEqual(reloaded.chains[0].createdAt, createdAt)
        XCTAssertEqual(reloaded.chains[0].name, "New")
        XCTAssertEqual(reloaded.chains[0].steps, newSteps)
    }

    func test_update_unknown_id_returns_false() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        let snapshot = store.chains
        XCTAssertFalse(store.update(id: UUID(), name: "New", steps: [.action(actionId: .items)]))
        XCTAssertEqual(store.chains, snapshot)
    }

    func test_update_allows_same_name_on_self() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        let id = store.chains[0].id
        // Same name, different steps — the duplicate-name check must exclude self.
        XCTAssertTrue(store.update(id: id, name: "Memo Flow", steps: [.action(actionId: .mece)]))
        XCTAssertEqual(store.chains.count, 1)
        XCTAssertEqual(store.chains[0].name, "Memo Flow")
        XCTAssertEqual(store.chains[0].steps, [.action(actionId: .mece)])
    }

    func test_update_rejects_duplicate_name_of_other() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "alpha", steps: [.action(actionId: .memo)]))
        XCTAssertTrue(store.add(name: "beta", steps: [.action(actionId: .mece)]))
        let bId = store.chains[1].id
        let bSnapshot = store.chains[1]
        // Renaming B to A's name (different case) must be rejected.
        XCTAssertFalse(store.update(id: bId, name: "ALPHA", steps: [.action(actionId: .items)]))
        XCTAssertEqual(store.chains[1], bSnapshot)
    }

    // MARK: - normalizedName()

    func test_normalizedName() {
        XCTAssertEqual(ChainStore.normalizedName("  Memo Flow "), "memo flow")
        XCTAssertNil(ChainStore.normalizedName(""))
        XCTAssertNil(ChainStore.normalizedName("   "))
    }

    // MARK: - chain(named:)

    func test_chain_named_is_case_insensitive_via_normalization() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))
        // Lookup normalizes through the same function as storage — no dead entries.
        XCTAssertEqual(store.chain(named: "  MEMO flow ")?.name, "Memo Flow")
        XCTAssertNil(store.chain(named: "nope"))
    }

    // MARK: - Seeding

    func test_seed_on_first_run_populates() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: true)
        XCTAssertEqual(store.chains.count, ChainStore.seedChains.count)
        XCTAssertEqual(store.chains.map(\.name), ChainStore.seedChains.map(\.name))
    }

    func test_seed_chains_have_nonempty_steps_and_no_live_capture() {
        XCTAssertFalse(ChainStore.seedChains.isEmpty, "There must be at least one seed chain")
        for seed in ChainStore.seedChains {
            XCTAssertFalse(seed.steps.isEmpty,
                           "Seed chain '\(seed.name)' must have non-empty steps")
            for step in seed.steps {
                if case .capture = step {
                    XCTFail("Seed chain '\(seed.name)' must not contain a .capture step — seeds must be useful without interactive recording")
                }
            }
        }
    }

    func test_no_seed_when_flag_false() {
        let store = ChainStore(fileURL: tmpURL(), seedOnFirstRun: false)
        XCTAssertTrue(store.chains.isEmpty)
    }

    func test_no_seed_when_file_exists() {
        let url = tmpURL()
        let first = ChainStore(fileURL: url, seedOnFirstRun: false)
        XCTAssertTrue(first.add(name: "Memo Flow", steps: [.action(actionId: .memo)]))

        let second = ChainStore(fileURL: url, seedOnFirstRun: true)
        XCTAssertEqual(second.chains.count, 1)
        XCTAssertEqual(second.chains.first?.name, "Memo Flow")
    }

    // MARK: - ChainStep Codable (hand-rolled enum)

    func test_chainStep_codable_roundtrip() throws {
        let original: [ChainStep] = [
            .capture(mode: .quick),
            .action(actionId: .memo),
            .insert(targetHint: "Notes"),
            .insert(targetHint: nil),
        ]
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode([ChainStep].self, from: data)
        // Proves the hand-rolled associated-value Codable round-trips, including
        // the nil targetHint case.
        XCTAssertEqual(decoded, original)
    }

    func test_chainStep_decode_unknown_kind_throws() {
        // Hand-craft JSON with an unrecognized `kind` discriminator. The
        // hand-rolled decoder must THROW a DecodingError rather than silently
        // dropping or defaulting the step.
        let json = Data("""
        [{"kind":"bogus"}]
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode([ChainStep].self, from: json))
    }

    // ── R5.6: app-level step kinds for voice protocols ──

    func testNewStepKindsRoundTripThroughCodable() throws {
        let steps: [ChainStep] = [
            .setMode(mode: "meeting"),
            .setTone(tone: "formal"),
            .openWindow(window: "cockpit"),
        ]
        let data = try JSONEncoder().encode(steps)
        let decoded = try JSONDecoder().decode([ChainStep].self, from: data)
        XCTAssertEqual(decoded, steps)
    }

    func testNewStepSummaries() {
        XCTAssertEqual(ChainStep.setMode(mode: "meeting").summary, "Mode: meeting")
        XCTAssertEqual(ChainStep.setTone(tone: "formal").summary, "Tone: formal")
        XCTAssertEqual(ChainStep.openWindow(window: "cockpit").summary, "Open: cockpit")
    }
}

