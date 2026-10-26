import Foundation

/// Occurrences of one word (or root) where each is within `limit` words of the next (SPEC §4.3).
public struct RepeatGroup: Sendable, Equatable {
    /// The comparison key: the root in same-root mode, otherwise the lowercased word.
    public let word: String
    public let tier: Tier
    public let limit: Int
    public let ranges: [NSRange]
    /// Index of each occurrence in the token stream, so gaps can be shown ("repeated 18 words earlier").
    public let positions: [Int]

    /// Words between occurrence `i` and the one before it, or `nil` for the first.
    public func gap(before i: Int) -> Int? {
        i > 0 ? positions[i] - positions[i - 1] : nil
    }
}

public struct WatchHit: Sendable, Equatable {
    /// Index into `EngineSettings.watchList`.
    public let entry: Int
    /// Covers the whole phrase for multi-word entries.
    public let range: NSRange
}

/// One highlight for the overlay, sorted by location in `AnalysisResult.matches`.
public struct Match: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Occurrence `index` of `repeatGroups[group]`.
        case repeated(group: Int, index: Int)
        /// `watchHits[hit]`.
        case watch(hit: Int)
    }

    public let range: NSRange
    public let kind: Kind
}

public struct Report: Sendable, Equatable {
    public struct WordCount: Sendable, Equatable {
        public let word: String
        public let count: Int
        public let tier: Tier
        public let repeatGroups: Int
        /// Every occurrence in the text, for jumping through them.
        public let ranges: [NSRange]
    }

    public struct WatchCount: Sendable, Equatable {
        public let pattern: String
        public let count: Int
        public let perThousand: Double
        public let maxPerThousand: Double?
        /// False when a threshold is set and the rate is at or under it.
        public let flagged: Bool
        /// Every occurrence, including unflagged ones under the threshold.
        public let ranges: [NSRange]
    }

    public let wordCount: Int
    /// The 25 most frequent flaggable words (not excluded, ignored or names), most frequent first.
    public let topWords: [WordCount]
    public let watch: [WatchCount]
    public let repeatGroupsByTier: [Tier: Int]

    /// "Copy report" text for the Check Text window (SPEC §5.6).
    public func plainText() -> String {
        var lines = ["Echo report — \(wordCount) words", "", "Most repeated words:"]
        for w in topWords {
            lines.append("  \(w.word): \(w.count)× (\(w.tier.label)), \(w.repeatGroups) close repeat\(w.repeatGroups == 1 ? "" : "s")")
        }
        if !watch.isEmpty {
            lines += ["", "Watch list (per 1,000 words):"]
            for w in watch {
                let limit = w.maxPerThousand.map { String(format: ", limit %.1f", $0) } ?? ""
                lines.append(String(format: "  %@: %d× — %.1f%@", w.pattern, w.count, w.perThousand, limit))
            }
        }
        lines += ["", "Close repeats by rarity:"]
        for tier in Tier.allCases {
            lines.append("  \(tier.label): \(repeatGroupsByTier[tier] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }
}

public struct AnalysisResult: Sendable {
    public let tokens: [Token]
    public let repeatGroups: [RepeatGroup]
    public let watchHits: [WatchHit]
    /// Everything to highlight, sorted by location.
    public let matches: [Match]
    /// Words treated as character or place names and skipped (SPEC §4.7).
    public let properNouns: Set<String>
    public let report: Report

    public var wordCount: Int { tokens.count }
}
