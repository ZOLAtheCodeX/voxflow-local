import XCTest
@testable import VoxFlowApp

/// Provenance tagging exists so the JSONL audit receipt can answer the single
/// most important polish question — "did this dictation actually reach the
/// Gemma/Ollama model, or fall back to the regex floor / in-app cleanup?" The
/// backend already returns `served_by`/`model_id` on every cleanup; Swift used
/// to drop them, making the audit log unable to distinguish Gemma from regex.
final class PolishProvenanceTests: XCTestCase {

    func testRegexFloorLabel() {
        XCTAssertEqual(PolishProvenance.label(servedBy: "regex", modelId: nil), "regex fallback")
    }

    func testDeterministicRulesLabel() {
        XCTAssertEqual(PolishProvenance.label(servedBy: "rules", modelId: nil), "rules")
    }

    func testRealModelPrefersModelId() {
        XCTAssertEqual(
            PolishProvenance.label(servedBy: "ollama", modelId: "gemma4:e2b-mlx"),
            "gemma4:e2b-mlx"
        )
    }

    func testRealProviderWithoutModelFallsBackToProviderName() {
        XCTAssertEqual(PolishProvenance.label(servedBy: "ollama", modelId: nil), "ollama")
    }

    func testUnknownProvenanceIsEmptySoCallersCanOmitTheTag() {
        XCTAssertEqual(PolishProvenance.label(servedBy: nil, modelId: nil), "")
        XCTAssertEqual(PolishProvenance.label(servedBy: "", modelId: "ignored"), "")
    }

    func testInAppMarkerIsStable() {
        XCTAssertEqual(PolishProvenance.inApp, "in-app cleanup")
    }
}
