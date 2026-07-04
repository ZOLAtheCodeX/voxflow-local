import XCTest
@testable import VoxFlowApp

/// Focus-aware cockpit key routing. While the transcript editor (or any
/// editable text view — e.g. the Notion search field) is first responder,
/// ⌘Z/⌘C must pass through to native undo/copy-selection and esc must exit
/// editing (committing via focus loss) instead of closing the window. The
/// capture/insert/window shortcuts stay global in both states.
final class CockpitKeyRouterTests: XCTestCase {
    private let escKeyCode: UInt16 = 53
    private let otherKeyCode: UInt16 = 0

    // MARK: ⌘Z — smart-action undo vs native text undo

    func test_cmdZ_notEditing_undoesLastAction() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "z", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: false),
            .undo
        )
    }

    func test_cmdZ_editing_passesThroughToNativeUndo() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "z", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: true),
            .passThrough
        )
    }

    // MARK: ⌘C — whole-transcript copy vs native copy-selection

    func test_cmdC_notEditing_copiesTranscript() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "c", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: false),
            .copy
        )
    }

    func test_cmdC_editing_passesThroughToNativeCopy() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "c", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: true),
            .passThrough
        )
    }

    // MARK: ⌘↩ — commit the draft before inserting

    func test_cmdReturn_notEditing_insertsDirectly() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "\r", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: false),
            .insert
        )
    }

    func test_cmdReturn_editing_commitsDraftFirst() {
        // Mid-edit, the draft lives only in the TextEditor — inserting the
        // last COMMITTED transcript would ship stale text. The router demands
        // commit-then-insert so the shell resigns focus (committing via the
        // editor's focus-loss handler) before reading the transcript.
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "\r", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: true),
            .commitThenInsert
        )
    }

    // MARK: esc — two-step close while editing

    func test_esc_notEditing_closes() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "", keyCode: escKeyCode, modifiers: [], isTextEditingActive: false),
            .close
        )
    }

    func test_esc_editing_exitsEditingInsteadOfClosing() {
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "", keyCode: escKeyCode, modifiers: [], isTextEditingActive: true),
            .exitEditing
        )
    }

    // MARK: global shortcuts stay global while editing

    func test_globalShortcuts_unaffectedByEditingState() {
        for editing in [false, true] {
            XCTAssertEqual(
                CockpitKeyRouter.route(key: "r", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: editing),
                .record, "⌘R must stay global (editing=\(editing))"
            )
            XCTAssertEqual(
                CockpitKeyRouter.route(key: ".", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: editing),
                .stop, "⌘. must stay global (editing=\(editing))"
            )
            // ⌘↩ is asserted separately: it stays global but switches to
            // commit-then-insert while editing (see the dedicated tests).
            XCTAssertEqual(
                CockpitKeyRouter.route(key: "\\", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: editing),
                .toggleSidePanel, "⌘\\ must stay global (editing=\(editing))"
            )
            XCTAssertEqual(
                CockpitKeyRouter.route(key: "w", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: editing),
                .close, "⌘W must stay global (editing=\(editing))"
            )
        }
    }

    // MARK: everything else propagates

    func test_unmappedKeys_passThrough() {
        // Unmodified letter (typing) — both states.
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "a", keyCode: otherKeyCode, modifiers: [], isTextEditingActive: false),
            .passThrough
        )
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "a", keyCode: otherKeyCode, modifiers: [], isTextEditingActive: true),
            .passThrough
        )
        // ⌘ + unmapped key.
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "x", keyCode: otherKeyCode, modifiers: [.command], isTextEditingActive: false),
            .passThrough
        )
        // Non-command modifier combo on a mapped key.
        XCTAssertEqual(
            CockpitKeyRouter.route(key: "z", keyCode: otherKeyCode, modifiers: [.command, .shift], isTextEditingActive: false),
            .passThrough
        )
    }
}
