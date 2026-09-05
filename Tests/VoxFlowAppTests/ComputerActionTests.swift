import AppKit
import XCTest
@testable import VoxFlowApp

@MainActor
final class ComputerActionTests: XCTestCase {
    private func catalog() throws -> ComputerActionCatalog {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try ComputerActionCatalog.decode(Data(contentsOf: root.appendingPathComponent("backend/app/computer_actions.json")))
    }

    func testShippedCatalogHasUnambiguousCompletePhrasesAndRegisteredOperations() throws {
        let catalog = try catalog()
        XCTAssertEqual(catalog.actions.count, 12)
        let enabled = Set(catalog.actions.map(\.id))
        for action in catalog.actions {
            for phrase in action.phrases {
                XCTAssertEqual(catalog.resolve("Voxflow, \(phrase).", enabledIDs: enabled), action)
                XCTAssertEqual(catalog.resolve("Vox flow \(phrase)!", enabledIDs: enabled), action)
                XCTAssertNil(catalog.resolve(phrase, enabledIDs: enabled))
                XCTAssertNil(catalog.resolve("Voxflow \(phrase) when you are ready", enabledIDs: enabled))
                XCTAssertNil(catalog.resolve("Please write about Voxflow \(phrase)", enabledIDs: enabled))
                XCTAssertNil(catalog.resolve(action.example, enabledIDs: enabled.subtracting([action.id])))
            }
            if action.operation == .shortcut { XCTAssertNotNil(NativeComputerActionBridge.shortcut(action.argument)) }
        }
        XCTAssertNil(NativeComputerActionBridge.shortcut("return"))
        XCTAssertNil(NativeComputerActionBridge.shortcut("shell"))
    }

    func testMalformedOrAmbiguousCatalogDoesNotLoad() throws {
        let action = try XCTUnwrap(catalog().actions.first)
        let encoded = try JSONEncoder().encode(action)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for changes: [String: Any] in [["operation": "shell"], ["argument": "com.unregistered.app"],
                                      ["phrases": ["open finder", "open finder"]], ["phrases": ["open\nfinder"]]] {
            let modified = object.merging(changes) { _, value in value }
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "actions": [modified]])
            XCTAssertThrowsError(try ComputerActionCatalog.decode(data))
        }
        let duplicates = try JSONSerialization.data(withJSONObject: ["version": 1, "actions": [object, object]])
        XCTAssertThrowsError(try ComputerActionCatalog.decode(duplicates))
        let future = try JSONSerialization.data(withJSONObject: ["version": 2, "actions": [object]])
        XCTAssertThrowsError(try ComputerActionCatalog.decode(future))
    }

    func testModesAndIndividualChoicesPersistWithoutEnablingFutureActions() throws {
        let suite = "voxflow-computer-actions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let full = try catalog()
        let initial = ComputerActionCatalog(version: 1, actions: Array(full.actions.prefix(2)))
        let settings = ComputerActionSettings(defaults: defaults, catalog: initial)
        XCTAssertEqual(settings.mode, .customPrompts)
        XCTAssertFalse(settings.mode.includesComputerActions)
        let id = initial.actions[0].id
        settings.setEnabled(false, id: id)
        settings.setEnabled(true, id: "unknown")
        for mode in VoiceActionMode.allCases {
            settings.setMode(mode)
            let reloaded = ComputerActionSettings(defaults: defaults, catalog: full)
            XCTAssertEqual(reloaded.mode, mode)
            XCTAssertEqual(reloaded.enabledIDs, [initial.actions[1].id])
        }
        let matrix: [(VoiceActionMode, Bool, Bool)] = [(.off, false, false), (.customPrompts, true, false),
                                                     (.computerActions, false, true), (.all, true, true)]
        for (mode, custom, builtIn) in matrix {
            XCTAssertEqual(mode.includesCustomPrompts, custom)
            XCTAssertEqual(mode.includesComputerActions, builtIn)
        }
        defaults.set("future-mode", forKey: ComputerActionSettings.modeKey)
        defaults.set("invalid", forKey: ComputerActionSettings.enabledKey)
        let invalid = ComputerActionSettings(defaults: defaults, catalog: full)
        XCTAssertEqual(invalid.mode, .off)
        XCTAssertTrue(invalid.enabledIDs.isEmpty)
    }

    func testValidActionCrossesPreparationAndBridgeExactlyOnce() async throws {
        let action = try XCTUnwrap(catalog().actions.first)
        let bridge = BridgeFake()
        let service = ComputerActionService(preparer: PreparerFake { Self.prepared($0) }, bridge: bridge)
        let permissions = CapturedVoiceActions(mode: .all, enabledIDs: [action.id])
        let outcome = try await service.execute(action, permissions: permissions, target: nil, focus: nil)
        XCTAssertEqual(outcome, .applicationOpened)
        XCTAssertEqual(bridge.actions, [Self.prepared(action)])
    }

    func testRevocationDuringPreparationPreventsEveryEffect() async throws {
        let action = try XCTUnwrap(catalog().actions.first)
        let permissions = CapturedVoiceActions(mode: .all, enabledIDs: [action.id])
        let bridge = BridgeFake()
        let service = ComputerActionService(preparer: PreparerFake { action in
            await permissions.revoke()
            return Self.prepared(action)
        }, bridge: bridge)
        do {
            _ = try await service.execute(action, permissions: permissions, target: nil, focus: nil)
            XCTFail("Revoked action executed")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(bridge.actions.isEmpty)
    }

    func testDisabledCanceledAndMismatchedRequestsNeverReachBridge() async throws {
        let action = try XCTUnwrap(catalog().actions.first)
        for mode in [VoiceActionMode.off, .customPrompts, .all] {
            let bridge = BridgeFake()
            let service = ComputerActionService(preparer: PreparerFake { Self.prepared($0) }, bridge: bridge)
            let permissions = CapturedVoiceActions(mode: mode, enabledIDs: mode == .all ? [] : [action.id])
            do {
                _ = try await service.execute(action, permissions: permissions, target: nil, focus: nil)
                XCTFail("Disabled action executed")
            } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(bridge.actions.isEmpty)
        }
        for invalid: PreparedComputerAction in [
            .init(version: 2, id: action.id, operation: action.operation, argument: action.argument),
            .init(version: 1, id: "another", operation: action.operation, argument: action.argument),
            .init(version: 1, id: action.id, operation: .shortcut, argument: "paste"),
            .init(version: 1, id: action.id, operation: action.operation, argument: "com.unregistered.app")
        ] {
            let bridge = BridgeFake()
            let service = ComputerActionService(preparer: PreparerFake { _ in invalid }, bridge: bridge)
            do {
                _ = try await service.execute(action, permissions: .init(mode: .all, enabledIDs: [action.id]), target: nil, focus: nil)
                XCTFail("Mismatched plan executed")
            } catch { }
            XCTAssertTrue(bridge.actions.isEmpty)
        }
        let bridge = BridgeFake()
        let service = ComputerActionService(preparer: PreparerFake { _ in throw CancellationError() }, bridge: bridge)
        do {
            _ = try await service.execute(action, permissions: .init(mode: .all, enabledIDs: [action.id]), target: nil, focus: nil)
            XCTFail("Canceled action executed")
        } catch { }
        XCTAssertTrue(bridge.actions.isEmpty)
    }

    func testBridgeFailureIsNotRetried() async throws {
        let action = try XCTUnwrap(catalog().actions.first)
        let bridge = BridgeFake()
        bridge.fail = true
        let service = ComputerActionService(preparer: PreparerFake { Self.prepared($0) }, bridge: bridge)
        do {
            _ = try await service.execute(action, permissions: .init(mode: .all, enabledIDs: [action.id]), target: nil, focus: nil)
            XCTFail("Failed bridge reported success")
        } catch { }
        XCTAssertEqual(bridge.actions.count, 1)
    }

    nonisolated private static func prepared(_ action: ComputerAction) -> PreparedComputerAction {
        .init(version: 1, id: action.id, operation: action.operation, argument: action.argument)
    }

    private struct PreparerFake: ComputerActionPreparing {
        let prepareBody: @Sendable (ComputerAction) async throws -> PreparedComputerAction
        init(_ body: @escaping @Sendable (ComputerAction) async throws -> PreparedComputerAction) { prepareBody = body }
        func prepare(_ action: ComputerAction) async throws -> PreparedComputerAction { try await prepareBody(action) }
    }
    private final class BridgeFake: ComputerActionPerforming {
        var actions: [PreparedComputerAction] = []
        var fail = false
        func perform(_ action: PreparedComputerAction, permissions: CapturedVoiceActions, target: NSRunningApplication?, focus: CapturedInsertionFocus?) async throws -> ComputerActionOutcome {
            actions.append(action)
            if fail { throw ComputerActionError.targetChanged }
            return .applicationOpened
        }
    }
}
