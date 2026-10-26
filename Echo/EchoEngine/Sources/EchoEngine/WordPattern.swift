import Foundation

/// A list entry: one or more words, each optionally with `*` at the start and/or end.
struct WordPattern {
    enum Part: Equatable {
        case exact(String)
        case prefix(String)    // look*
        case suffix(String)    // *ly
        case contains(String)  // *ish*

        func matches(_ word: String) -> Bool {
            switch self {
            case .exact(let s): word == s
            case .prefix(let s): word.hasPrefix(s)
            case .suffix(let s): word.hasSuffix(s)
            case .contains(let s): word.contains(s)
            }
        }
    }

    let parts: [Part]

    init?(_ entry: String) {
        let words = entry.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: \.isWhitespace)
        let parts = words.compactMap { w -> Part? in
            let lead = w.hasPrefix("*"), trail = w.hasSuffix("*")
            let core = String(w.drop(while: { $0 == "*" }).reversed().drop(while: { $0 == "*" }).reversed())
            guard !core.isEmpty else { return nil }
            switch (lead, trail) {
            case (true, true): return .contains(core)
            case (true, false): return .suffix(core)
            case (false, true): return .prefix(core)
            case (false, false): return .exact(core)
            }
        }
        guard !parts.isEmpty, parts.count == words.count else { return nil }
        self.parts = parts
    }
}

/// Single-word list (exclude or ignore): exact entries in a set, wildcard entries checked one by one.
/// Multi-word entries are ignored here; phrases only make sense on the watch list.
struct WordSet {
    private var exact: Set<String> = []
    private var wildcards: [WordPattern.Part] = []

    init(_ entries: [String]) {
        for entry in entries {
            guard let p = WordPattern(entry), p.parts.count == 1 else { continue }
            if case .exact(let s) = p.parts[0] { exact.insert(s) } else { wildcards.append(p.parts[0]) }
        }
    }

    func contains(_ word: String) -> Bool {
        exact.contains(word) || wildcards.contains { $0.matches(word) }
    }
}
