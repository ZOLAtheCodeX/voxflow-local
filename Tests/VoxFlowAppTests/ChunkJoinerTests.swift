import XCTest
@testable import VoxFlowApp

final class ChunkJoinerTests: XCTestCase {
    func test_sentence_end_then_capital_gets_one_space() {
        XCTAssertEqual(ChunkJoiner.join("world.", "Second"), "world. Second")
    }

    func test_opening_quote_in_next_keeps_space() {
        XCTAssertEqual(ChunkJoiner.join("He said", "“hello”"), "He said “hello”")
    }

    func test_closing_paren_attaches() {
        XCTAssertEqual(ChunkJoiner.join("(note", ")"), "(note)")
    }

    func test_comma_attaches() {
        XCTAssertEqual(ChunkJoiner.join("Hello", ","), "Hello,")
    }

    func test_trailing_newlines_are_not_padded() {
        XCTAssertEqual(ChunkJoiner.join("x\n\n", "y"), "x\n\ny")
    }

    func test_percent_attaches() {
        XCTAssertEqual(ChunkJoiner.join("rate", "%"), "rate%")
    }

    func test_split_number_joins_with_space_known_limitation() {
        XCTAssertEqual(ChunkJoiner.join("3", "14"), "3 14")
    }

    func test_empty_previous_returns_next() {
        XCTAssertEqual(ChunkJoiner.join("", "Start"), "Start")
    }

    func test_opening_quote_in_previous_attaches() {
        XCTAssertEqual(ChunkJoiner.join("open “", "quoted"), "open “quoted")
    }

    func test_inverted_question_mark_attaches() {
        XCTAssertEqual(ChunkJoiner.join("¿", "Qué"), "¿Qué")
    }

    func test_ellipsis_attaches() {
        XCTAssertEqual(ChunkJoiner.join("wait", "…"), "wait…")
    }

    func test_straight_quote_keeps_space() {
        XCTAssertEqual(ChunkJoiner.join("say", "\"hi\""), "say \"hi\"")
    }

    func test_empty_next_adds_nothing() {
        XCTAssertEqual(ChunkJoiner.join("done", ""), "done")
    }
}
