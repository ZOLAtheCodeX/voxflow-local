import XCTest

/// Keeps color, font and motion literals out of views. Everything under
/// `Sources/VoxFlowApp/Views/` goes through `VFDesignTokens.swift` (colors,
/// type) and through the Reduce Motion aware modifiers (repeating motion).
///
/// `pendingFiles` is the baseline of views allowed to carry literals. It is
/// empty and must stay empty: the second test fails if anyone adds a file to
/// it, so the baseline cannot silently regrow.
final class DesignTokenLintTests: XCTestCase {

    static let pendingFiles: Set<String> = []

    private struct Rule {
        let name: String
        let pattern: NSRegularExpression
        /// Files exempt from this rule, by last path component.
        let exemptFiles: Set<String>
    }

    private struct Violation: Comparable, CustomStringConvertible {
        let file: String
        let line: Int
        let rule: String
        var description: String { "\(file):\(line):\(rule)" }
        static func < (a: Violation, b: Violation) -> Bool {
            (a.file, a.line, a.rule) < (b.file, b.line, b.rule)
        }
    }

    private static let colorNames = "green|orange|red|blue|purple|mint|yellow|pink|teal|cyan|indigo|brown"

    private static let rules: [Rule] = {
        let tokenFile: Set<String> = ["VFDesignTokens.swift"]
        // VFModifiers.swift (Task 4) owns the Reduce Motion aware wrappers, so
        // it is exempt from the motion rules only.
        let motionExempt = tokenFile.union(["VFModifiers.swift"])
        func rule(_ name: String, _ pattern: String, exempt: Set<String> = tokenFile) -> Rule {
            Rule(name: name, pattern: try! NSRegularExpression(pattern: pattern), exemptFiles: exempt)
        }
        return [
            rule("color: Color(red/hue/white:)", #"Color\((red|hue|white):"#),
            rule("color: Color(nsColor:)", #"Color\(nsColor:"#),
            rule("color: Color.gray.opacity", #"Color\.gray\.opacity"#),
            rule("color: Color.<system>", #"Color\.(\#(colorNames))\b"#),
            rule("color: .<system> shorthand", #"(?<![\w.])\.(\#(colorNames))\b"#),
            rule("type: .system(size:)", #"\.system\(size:"#),
            rule("motion: repeatForever", #"repeatForever"#, exempt: motionExempt),
            rule("motion: .symbolEffect(", #"\.symbolEffect\("#, exempt: motionExempt),
            rule("motion: VF.animationPulse", #"VF\.animationPulse"#, exempt: motionExempt),
        ]
    }()

    // MARK: - Tests

    func test_views_use_tokens_for_color_type_and_motion() throws {
        let violations = try scanViews().filter { !Self.pendingFiles.contains($0.file) }
        XCTAssertTrue(
            violations.isEmpty,
            "Literals outside VFDesignTokens.swift (use VF tokens or the motion modifiers):\n"
                + violations.map(\.description).joined(separator: "\n")
        )
    }

    func test_pending_baseline_stays_empty() {
        XCTAssertTrue(
            Self.pendingFiles.isEmpty,
            "pendingFiles must stay empty; fix the literals instead of listing the file: \(Self.pendingFiles.sorted())"
        )
    }

    // MARK: - Scanner

    private func scanViews() throws -> [Violation] {
        let viewsDir = try repoRoot().appendingPathComponent("Sources/VoxFlowApp/Views", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: viewsDir, includingPropertiesForKeys: nil) else {
            XCTFail("Cannot enumerate \(viewsDir.path)")
            return []
        }
        var found: [Violation] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let file = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                for rule in Self.rules where !rule.exemptFiles.contains(file) {
                    if rule.pattern.firstMatch(in: line, range: range) != nil {
                        found.append(Violation(file: file, line: index + 1, rule: rule.name))
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 10, "Lint scanned suspiciously few view files")
        return found.sorted()
    }

    /// Walks up from this file to the directory holding `Package.swift`.
    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        // A lint that cannot find the sources must fail, not skip: a skip
        // reads as green and the token rule would go unenforced.
        XCTFail("Package.swift not found above \(#filePath)")
        throw RepoRootNotFound()
    }

    private struct RepoRootNotFound: Error {}
}
