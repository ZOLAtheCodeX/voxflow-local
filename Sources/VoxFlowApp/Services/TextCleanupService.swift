import Foundation

enum TextCleanupService {

    static func replaceSpokenPunctuation(_ text: String) -> String {
        var result = text

        let replacements: [(pattern: String, replacement: String)] = [
            (#"\s+new paragraph\b\s*"#, "\n\n"),
            (#"\s+new ?line\b\s*"#, "\n"),
            (#"\s+period\b"#, "."),
            (#"\s+full stop\b"#, "."),
            (#"\s+comma\b"#, ","),
            (#"\s+question mark\b"#, "?"),
            (#"\s+exclamation (?:point|mark)\b"#, "!"),
            (#"\s+colon\b"#, ":"),
            (#"\s+semicolon\b"#, ";"),
            (#"\bopen quote\s+"#, "\""),
            (#"\s+close quote\b"#, "\""),
            (#"\s+dash\b"#, " —"),
            (#"\s+hyphen\b"#, "-"),
        ]

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return result
    }
}
