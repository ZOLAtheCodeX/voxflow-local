import XCTest
@testable import VoxFlowApp

/// Quick dictation admits a transcript in the same order as cockpit chunks:
/// the gate judges the raw decode (stripping Whisper's annotations), then the
/// user's dictionary applies to the cleaned text. Gating after the dictionary
/// silently deleted dictionary terms written with brackets ("[sic]").
@MainActor
final class QuickDictationAdmissionTests: XCTestCase {
    private let dictionary: (String) -> String = { $0.replacingOccurrences(of: "sick note", with: "[sic]") }

    func testDictionaryTermWithBracketsSurvivesTheGate() {
        let admission = AppCoordinator.admitQuickDictation(
            recognizedText: "he wrote sick note here", confidence: 0.9, audioDurationSeconds: 4,
            appliesDictionary: true, dictionary: dictionary)
        XCTAssertEqual(admission.verdict, .accepted)
        XCTAssertEqual(admission.text, "he wrote [sic] here")
    }

    func testAnnotationsAreStrippedBeforeTheDictionaryApplies() {
        let admission = AppCoordinator.admitQuickDictation(
            recognizedText: "[BLANK_AUDIO] he wrote sick note", confidence: 0.9, audioDurationSeconds: 4,
            appliesDictionary: true, dictionary: dictionary)
        XCTAssertEqual(admission.text, "he wrote [sic]")
    }

    func testSkillsAndActionsSkipTheDictionary() {
        let admission = AppCoordinator.admitQuickDictation(
            recognizedText: "he wrote sick note", confidence: 0.9, audioDurationSeconds: 4,
            appliesDictionary: false, dictionary: dictionary)
        XCTAssertEqual(admission.text, "he wrote sick note")
    }

    func testRejectionsDoNotApplyTheDictionary() {
        var applied = false
        let admission = AppCoordinator.admitQuickDictation(
            recognizedText: "(water rushing)", confidence: 0.45, audioDurationSeconds: 4,
            appliesDictionary: true, dictionary: { applied = true; return $0 })
        XCTAssertEqual(admission.verdict, .rejected(reason: .hallucinationFilter))
        XCTAssertFalse(applied)
    }
}
