import Foundation

enum TextCleanupRules {
    static let spokenPunctuation: [(pattern: String, replacement: String)] = [
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

    static let alwaysFillers: Set<String> = [
        "um", "umm", "uh", "uhh", "er", "err", "ah", "ahh", "hmm", "hm",
        "mm", "mmm", "mhm"
    ]

    static let ambiguousFillers: Set<String> = [
        "like", "so", "right", "actually", "basically", "literally",
        "anyway", "anyways"
    ]

    static let phraseFillers: [(pattern: String, replacement: String)] = [
        (#"\byou know\b"#, ""),
        (#"\bI mean\b"#, ""),
        (#"\bkind of\b"#, ""),
        (#"\bsort of\b"#, ""),
        (#"\bokay so\b"#, ""),
    ]

    static let hedgingPhrases: [(String, String)] = [
        (#"\bI think maybe\b"#, ""),
        (#"\bit seems like\b"#, ""),
        (#"\bin my opinion\b"#, ""),
        (#"\bI feel like\b"#, ""),
        (#"\bI guess\b"#, ""),
        (#"\bto be honest\b"#, ""),
    ]

    static let softeners: [(String, String)] = [
        (#"\bjust\b"#, ""),
        (#"\breally\b"#, ""),
        (#"\bvery\b"#, ""),
        (#"\bquite\b"#, ""),
        (#"\ba bit\b"#, ""),
    ]

    static let contractions: [(String, String)] = [
        (#"\bdon\u{2019}t\b"#, "do not"),
        (#"\bdon't\b"#, "do not"),
        (#"\bcan\u{2019}t\b"#, "cannot"),
        (#"\bcan't\b"#, "cannot"),
        (#"\bwon\u{2019}t\b"#, "will not"),
        (#"\bwon't\b"#, "will not"),
        (#"\bshouldn\u{2019}t\b"#, "should not"),
        (#"\bshouldn't\b"#, "should not"),
        (#"\bwouldn\u{2019}t\b"#, "would not"),
        (#"\bwouldn't\b"#, "would not"),
        (#"\bcouldn\u{2019}t\b"#, "could not"),
        (#"\bcouldn't\b"#, "could not"),
        (#"\bisn\u{2019}t\b"#, "is not"),
        (#"\bisn't\b"#, "is not"),
        (#"\baren\u{2019}t\b"#, "are not"),
        (#"\baren't\b"#, "are not"),
        (#"\bwasn\u{2019}t\b"#, "was not"),
        (#"\bwasn't\b"#, "was not"),
        (#"\bweren\u{2019}t\b"#, "were not"),
        (#"\bweren't\b"#, "were not"),
        (#"\bhasn\u{2019}t\b"#, "has not"),
        (#"\bhasn't\b"#, "has not"),
        (#"\bhaven\u{2019}t\b"#, "have not"),
        (#"\bhaven't\b"#, "have not"),
        (#"\bhadn\u{2019}t\b"#, "had not"),
        (#"\bhadn't\b"#, "had not"),
        (#"\bdoesn\u{2019}t\b"#, "does not"),
        (#"\bdoesn't\b"#, "does not"),
        (#"\bdidn\u{2019}t\b"#, "did not"),
        (#"\bdidn't\b"#, "did not"),
        (#"\bI\u{2019}m\b"#, "I am"),
        (#"\bI'm\b"#, "I am"),
        (#"\bI\u{2019}ve\b"#, "I have"),
        (#"\bI've\b"#, "I have"),
        (#"\bI\u{2019}ll\b"#, "I will"),
        (#"\bI'll\b"#, "I will"),
        (#"\bI\u{2019}d\b"#, "I would"),
        (#"\bI'd\b"#, "I would"),
        (#"\bwe\u{2019}re\b"#, "we are"),
        (#"\bwe're\b"#, "we are"),
        (#"\bwe\u{2019}ve\b"#, "we have"),
        (#"\bwe've\b"#, "we have"),
        (#"\bwe\u{2019}ll\b"#, "we will"),
        (#"\bwe'll\b"#, "we will"),
        (#"\bthey\u{2019}re\b"#, "they are"),
        (#"\bthey're\b"#, "they are"),
        (#"\bthey\u{2019}ve\b"#, "they have"),
        (#"\bthey've\b"#, "they have"),
        (#"\bthey\u{2019}ll\b"#, "they will"),
        (#"\bthey'll\b"#, "they will"),
        (#"\byou\u{2019}re\b"#, "you are"),
        (#"\byou're\b"#, "you are"),
        (#"\byou\u{2019}ve\b"#, "you have"),
        (#"\byou've\b"#, "you have"),
        (#"\byou\u{2019}ll\b"#, "you will"),
        (#"\byou'll\b"#, "you will"),
        (#"\bit\u{2019}s\b"#, "it is"),
        (#"\bit's\b"#, "it is"),
        (#"\bthat\u{2019}s\b"#, "that is"),
        (#"\bthat's\b"#, "that is"),
        (#"\bwho\u{2019}s\b"#, "who is"),
        (#"\bwho's\b"#, "who is"),
        (#"\bwhat\u{2019}s\b"#, "what is"),
        (#"\bwhat's\b"#, "what is"),
        (#"\bthere\u{2019}s\b"#, "there is"),
        (#"\bthere's\b"#, "there is"),
        (#"\bhere\u{2019}s\b"#, "here is"),
        (#"\bhere's\b"#, "here is"),
        (#"\blet\u{2019}s\b"#, "let us"),
        (#"\blet's\b"#, "let us"),
    ]

    static let casualInterjections: [(String, String)] = [
        (#"\bokay so\b"#, ""),
        (#"\balright\b"#, ""),
        (#"\bhey\b"#, ""),
        (#"\byeah\b"#, "yes"),
        (#"\bnope\b"#, "no"),
    ]
}
