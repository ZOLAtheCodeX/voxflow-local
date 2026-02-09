import Foundation

enum CommandIntent: Equatable {
    case switchToDictation
    case switchToTranslate
    case switchToMeeting
    case switchToLocalProvider
    case switchToPrivateProvider
    case switchToVoxtralSTT
    case switchToWhisperSTT
    case switchToOpenAISTT
    case setTone(ToneStyle)
    case approve
    case insert
    case copy
    case retry
    case undo
    case runBenchmark
}

enum CommandParser {
    static func parse(from rawText: String) -> CommandIntent? {
        let words = rawText.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map(String.init)
        let joined = words.joined(separator: " ")

        let modePatterns: [(keywords: [String], intent: CommandIntent)] = [
            (["meeting", "mode"], .switchToMeeting),
            (["translate", "mode"], .switchToTranslate),
            (["translation", "mode"], .switchToTranslate),
            (["dictation", "mode"], .switchToDictation),
            (["normal", "mode"], .switchToDictation),
            (["local", "mode"], .switchToLocalProvider),
            (["local", "provider"], .switchToLocalProvider),
            (["api", "mode"], .switchToPrivateProvider),
            (["private", "api"], .switchToPrivateProvider),
            (["voxtral", "stt"], .switchToVoxtralSTT),
            (["voxtral", "speech"], .switchToVoxtralSTT),
            (["whisper", "stt"], .switchToWhisperSTT),
            (["whisper", "speech"], .switchToWhisperSTT),
            (["openai", "stt"], .switchToOpenAISTT),
            (["openai", "speech"], .switchToOpenAISTT),
            (["tone", "formal"], .setTone(.formal)),
            (["formal", "tone"], .setTone(.formal)),
            (["tone", "concise"], .setTone(.concise)),
            (["concise", "tone"], .setTone(.concise)),
            (["tone", "friendly"], .setTone(.friendly)),
            (["friendly", "tone"], .setTone(.friendly)),
            (["tone", "neutral"], .setTone(.neutral)),
            (["neutral", "tone"], .setTone(.neutral)),
        ]

        for (keywords, intent) in modePatterns {
            if keywords.allSatisfy({ words.contains($0) }) {
                return intent
            }
        }

        let singleWordCommands: [(String, CommandIntent)] = [
            ("approve", .approve),
            ("insert", .insert),
            ("copy", .copy),
            ("retry", .retry),
            ("undo", .undo),
            ("benchmark", .runBenchmark),
        ]

        for (keyword, intent) in singleWordCommands {
            if joined == keyword || joined.hasPrefix("\(keyword) ") || joined.hasSuffix(" \(keyword)") {
                return intent
            }
        }

        return nil
    }
}
