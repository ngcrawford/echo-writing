import AppKit
import EchoEngine

/// Colors and hover text shared by the Check Text window and the in-app overlay.
enum Highlights {
    static let repeatColor = NSColor.systemOrange
    static let watchColor = NSColor.systemBlue

    static func color(for match: Match) -> NSColor {
        switch match.kind {
        case .repeated: repeatColor
        case .watch: watchColor
        }
    }

    /// How strongly to draw a highlight, 0–1. A repeated rare word ("sickbay") jumps out at readers far more
    /// than a repeated common one ("way"), so rare words are boldest; watch-list words use one fixed strength.
    static func strength(for tier: Tier?) -> CGFloat {
        guard let tier else { return 0.85 }
        return [0.3, 0.45, 0.65, 0.85, 1.0][tier.rawValue]
    }

    static func strength(for match: Match, in result: AnalysisResult) -> CGFloat {
        if case .repeated(let g, _) = match.kind { return strength(for: result.repeatGroups[g].tier) }
        return strength(for: nil)
    }

    /// Hover text for every match, in the same order as `result.matches`. `text` is what was analyzed; the
    /// hover quotes the word as written rather than its root ("George", not "georg").
    static func explanations(for result: AnalysisResult, text: String) -> [String] {
        let text = text as NSString
        var watchCountAt: [Int: Report.WatchCount] = [:]
        for count in result.report.watch {
            for range in count.ranges { watchCountAt[range.location] = count }
        }
        return result.matches.map { match in
            let word = NSMaxRange(match.range) <= text.length ? text.substring(with: match.range) : nil
            return explanation(for: match, word: word, in: result, watchCountAt: watchCountAt)
        }
    }

    /// e.g. "“gossamer” (uncommon) — 312 words after the previous one. Limit: 500 words."
    private static func explanation(for match: Match, word: String?, in result: AnalysisResult,
                                    watchCountAt: [Int: Report.WatchCount]) -> String {
        switch match.kind {
        case .repeated(let g, let i):
            let group = result.repeatGroups[g]
            var parts: [String] = []
            if let before = group.gap(before: i) { parts.append("\(before) words after the previous one") }
            if i + 1 < group.positions.count {
                parts.append("\(group.positions[i + 1] - group.positions[i]) words before the next")
            }
            return "“\(word ?? group.word)” (\(group.tier.label)) — \(parts.joined(separator: ", ")). Limit: \(group.limit) words."
        case .watch(let h):
            guard let count = watchCountAt[result.watchHits[h].range.location] else { return "Watch list" }
            return String(format: "Watch list: “%@” — %d× in this text (%.1f per 1,000 words).",
                          count.pattern, count.count, count.perThousand)
        }
    }
}
