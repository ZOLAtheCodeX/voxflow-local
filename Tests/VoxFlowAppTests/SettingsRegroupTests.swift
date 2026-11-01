import XCTest
@testable import VoxFlowApp

/// Pins the Settings regroup: the permission vocabulary, the six tabs, and the
/// retired section names that must not come back in the Settings views.
@MainActor
final class SettingsRegroupTests: XCTestCase {

    func test_permission_status_uses_the_shared_vocabulary() {
        XCTAssertEqual(PrivacySettingsPane.permissionStatus(granted: true), VFStatus(.ready, "Granted"))
        XCTAssertEqual(PrivacySettingsPane.permissionStatus(granted: false), VFStatus(.attention, "Missing"))
    }

    func test_settings_tabs_are_the_six_task_groups() {
        let tabs: [SettingsTab] = [.general, .apps, .voice, .models, .privacy, .advanced]
        XCTAssertEqual(Set(tabs).count, 6)
    }

    func test_settings_views_do_not_carry_retired_names_or_em_dashes() throws {
        let views = try repoRoot().appendingPathComponent("Sources/VoxFlowApp/Views", isDirectory: true)
        let files = (try FileManager.default.contentsOfDirectory(at: views.appendingPathComponent("Settings"), includingPropertiesForKeys: nil))
            + [views.appendingPathComponent("SettingsView.swift"),
               views.appendingPathComponent("SkillProfileSettingsView.swift"),
               views.appendingPathComponent("ComputerActionSettingsView.swift"),
               views.appendingPathComponent("VocabularySettingsView.swift")]
        let retired = ["Command lane", "STT Backend", "Dictation Tools", "Voice Action Prompts",
                       "Voice action controls", "Activation Targeting", "Open Setup Wizard", "\"Skills: "]
        var problems: [String] = []
        for file in files where file.pathExtension == "swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                for name in retired where line.contains(name) {
                    problems.append("\(file.lastPathComponent):\(index + 1): \(name)")
                }
                if line.contains("\u{2014}") {
                    problems.append("\(file.lastPathComponent):\(index + 1): em dash")
                }
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("Package.swift not found above \(#filePath)")
    }
}
