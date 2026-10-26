import Foundation
import NaturalLanguage

/// Maps words to their root (`walked` → `walk`, `children` → `child`) using Apple's NLTagger.
///
/// Tags one distinct word at a time and caches it: tagging a whole 130k-word novel in context takes ~1.1 s,
/// while the ~7k distinct words take ~120 ms once and are free afterwards. A bare word often gets no lemma
/// (`sat`, `sisters`), so it is retried inside a verb frame and then a noun frame. Words that still have no
/// lemma, and words with apostrophes or hyphens, are their own root.
final class Lemmatizer: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private let tagger = NLTagger(tagSchemes: [.lemma])
    private static let frames: [(String, String)] = [("", ""), ("they ", " it."), ("the ", ".")]

    func lemma(of word: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[word] { return cached }
        let result = tag(word) ?? word
        cache[word] = result
        return result
    }

    private func tag(_ word: String) -> String? {
        if word.contains("'") || word.contains("-") || word.contains("‐") { return nil }
        for (prefix, suffix) in Self.frames {
            let s = prefix + word + suffix
            tagger.string = s
            let at = s.index(s.startIndex, offsetBy: prefix.count)
            if let lemma = tagger.tag(at: at, unit: .word, scheme: .lemma).0?.rawValue.lowercased(),
               !lemma.isEmpty, !lemma.contains(" ") {
                return lemma
            }
        }
        return nil
    }
}
