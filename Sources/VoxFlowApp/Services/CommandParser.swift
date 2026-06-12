import Foundation

enum CommandIntent: Equatable {
    case switchToDictation
    case switchToTranslate
    case switchToMeeting
    case switchToLocalProvider
    case switchToPrivateProvider
    case switchToWhisperSTT
    case switchToOpenAISTT
    case setTone(ToneStyle)
    case approve
    case insert
    case copy
    case retry
    case undo
    case runBenchmark
    case switchToPromptMode
    case openCockpit
    case openDashboard
    /// R5.6: voice-triggered protocol (a named workflow chain). Only emitted
    /// for a strict full-utterance match — see parseProtocolTrigger.
    case runProtocol(name: String)
}

enum CommandParser {
    static func parse(from rawText: String) -> CommandIntent? {
        let words = rawText.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .split(separator: " ")
            .map(String.init)
        let joined = words.joined(separator: " ")

        // R5.6: protocol trigger first — strict full-utterance grammar so a
        // hallucinated fragment or mid-sentence mention never fires a macro.
        if let protocolName = parseProtocolTrigger(words: words) {
            return .runProtocol(name: protocolName)
        }

        // R5.3: window intents.
        if joined == "open cockpit" || joined == "open the cockpit" { return .openCockpit }
        if joined == "open dashboard" || joined == "open the dashboard" { return .openDashboard }

        let modePatterns: [(keywords: [String], intent: CommandIntent)] = [
            (["meeting", "mode"], .switchToMeeting),
            (["translate", "mode"], .switchToTranslate),
            (["translation", "mode"], .switchToTranslate),
            (["dictation", "mode"], .switchToDictation),
            (["prompt", "mode"], .switchToPromptMode),
            (["normal", "mode"], .switchToDictation),
            (["local", "mode"], .switchToLocalProvider),
            (["local", "provider"], .switchToLocalProvider),
            (["api", "mode"], .switchToPrivateProvider),
            (["private", "api"], .switchToPrivateProvider),
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

    /// "(run|start|execute) [the] <name> protocol" — the WHOLE utterance,
    /// nothing before or after. Returns the lowercased multi-word name
    /// (matches ChainStore.normalizedName).
    private static func parseProtocolTrigger(words: [String]) -> String? {
        guard words.count >= 3,
              ["run", "start", "execute"].contains(words[0]),
              words.last == "protocol" else { return nil }
        var nameWords = Array(words.dropFirst().dropLast())
        if nameWords.first == "the" { nameWords = Array(nameWords.dropFirst()) }
        guard !nameWords.isEmpty else { return nil }
        return nameWords.joined(separator: " ")
    }
}
