import Foundation

/// How far first-run setup has come. Only the microphone and Accessibility
/// are required for dictation to work; the engine and calibration improve it.
struct SetupProgress: Equatable {
    let microphone: Bool
    let accessibility: Bool
    let engine: Bool
    let calibration: Bool

    var doneCount: Int {
        [microphone, accessibility, engine, calibration].filter { $0 }.count
    }

    var total: Int { 4 }

    var remainingRequired: Int {
        [microphone, accessibility].filter { !$0 }.count
    }
}
