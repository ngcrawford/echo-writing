import Foundation

/// Finds proximity repeats and watch-list words in a text. Pure analysis: no UI, no Accessibility.
///
/// Reuse one instance: it caches word roots between calls, which makes re-analysis after an edit cheap.
public final class Analyzer: Sendable {
    public let frequencies: FrequencyTable
    private let lemmatizer = Lemmatizer()

    public init(frequencies: FrequencyTable) {
        self.frequencies = frequencies
    }

    public func analyze(_ text: String, settings: EngineSettings) -> AnalysisResult {
        let tokens = Tokenizer.tokenize(text, settings: settings)
        let roots = tokens.map { settings.matching == .sameRoot ? lemmatizer.lemma(of: $0.word) : $0.word }
        let properNouns = settings.detectProperNouns ? Self.properNouns(in: tokens) : []

        // Occurrences of each flaggable word, keyed by root (or word in exact mode).
        let exclude = WordSet(settings.excludeList)
        let ignore = WordSet(settings.ignoreList)
        var occurrences: [String: [Int]] = [:]
        var keyOrder: [String] = []
        for (i, token) in tokens.enumerated() {
            let root = roots[i]
            if properNouns.contains(token.word) || exclude.contains(token.word) || exclude.contains(root)
                || ignore.contains(token.word) || ignore.contains(root) {
                continue
            }
            if occurrences[root] == nil { keyOrder.append(root) }
            occurrences[root, default: []].append(i)
        }

        // Repeat groups: runs of occurrences each within the word's limit of the previous one.
        var groups: [RepeatGroup] = []
        var tierOfKey: [String: Tier] = [:]
        var groupsPerKey: [String: Int] = [:]
        for key in keyOrder {
            let positions = occurrences[key]!
            let surface = tokens[positions[0]].word
            let tier = settings.tier(forZipf: max(frequencies.zipf(key), frequencies.zipf(surface)))
            tierOfKey[key] = tier
            guard positions.count > 1 else { continue }
            let limit = settings.distanceOverrides[key] ?? settings.distanceOverrides[surface] ?? settings.distance(for: tier)

            var run = [positions[0]]
            func closeRun() {
                if run.count > 1 {
                    groups.append(RepeatGroup(word: key, tier: tier, limit: limit,
                                              ranges: run.map { tokens[$0].range }, positions: run))
                    groupsPerKey[key, default: 0] += 1
                }
            }
            for p in positions.dropFirst() {
                let previous = run.last!
                let linked = p - previous <= limit
                    && (!settings.resetAtParagraph || tokens[p].paragraph == tokens[previous].paragraph)
                if linked {
                    run.append(p)
                } else {
                    closeRun()
                    run = [p]
                }
            }
            closeRun()
        }

        let (watchHits, watchCounts) = findWatchHits(tokens: tokens, roots: roots, settings: settings)

        // A watch-list highlight wins over a repeat highlight on the same word; the repeat still counts in the report.
        let watched = Set(watchHits.flatMap { hit in (hit.range.location..<NSMaxRange(hit.range)) })
        var matches: [Match] = []
        for (g, group) in groups.enumerated() {
            for (i, range) in group.ranges.enumerated() where !watched.contains(range.location) {
                matches.append(Match(range: range, kind: .repeated(group: g, index: i)))
            }
        }
        for (h, hit) in watchHits.enumerated() {
            matches.append(Match(range: hit.range, kind: .watch(hit: h)))
        }
        matches.sort { $0.range.location < $1.range.location }

        let repeatedKeys: [(key: String, count: Int)] = keyOrder
            .map { (key: $0, count: occurrences[$0]!.count) }
            .filter { $0.count > 1 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
        let topWords = repeatedKeys.prefix(25).map {
            Report.WordCount(word: $0.key, count: $0.count, tier: tierOfKey[$0.key]!,
                             repeatGroups: groupsPerKey[$0.key] ?? 0,
                             ranges: occurrences[$0.key]!.map { tokens[$0].range })
        }
        var byTier: [Tier: Int] = [:]
        for group in groups { byTier[group.tier, default: 0] += 1 }

        return AnalysisResult(
            tokens: tokens, repeatGroups: groups, watchHits: watchHits, matches: matches,
            properNouns: properNouns,
            report: Report(wordCount: tokens.count, topWords: Array(topWords), watch: watchCounts,
                           repeatGroupsByTier: byTier))
    }

    /// A word is a name if every occurrence is capitalized and at least one is mid-sentence (SPEC §4.7).
    /// The frequency table can't decide this: it contains names (*elara* 1.4, *sarah* 4.5).
    static func properNouns(in tokens: [Token]) -> Set<String> {
        var alwaysCapitalized: [String: Bool] = [:]
        var midSentence: Set<String> = []
        for token in tokens {
            alwaysCapitalized[token.word] = (alwaysCapitalized[token.word] ?? true) && token.isCapitalized
            if token.isCapitalized && !token.startsSentence { midSentence.insert(token.word) }
        }
        return midSentence.filter { alwaysCapitalized[$0] == true && $0 != "i" }
    }

    private func findWatchHits(tokens: [Token], roots: [String], settings: EngineSettings)
        -> ([WatchHit], [Report.WatchCount])
    {
        let patterns = settings.watchList.map { WordPattern($0.pattern) }

        // Entries whose first word is exact are looked up by word; wildcard-first entries are tried everywhere.
        var byFirstWord: [String: [Int]] = [:]
        var wildcardFirst: [Int] = []
        for (e, pattern) in patterns.enumerated() {
            guard let pattern else { continue }
            if case .exact(let s) = pattern.parts[0] { byFirstWord[s, default: []].append(e) } else { wildcardFirst.append(e) }
        }

        func partMatches(_ part: WordPattern.Part, _ t: Int) -> Bool {
            if part.matches(tokens[t].word) { return true }
            // In same-root mode, an exact entry also catches other forms: "realize" flags "realized".
            if settings.matching == .sameRoot, case .exact(let s) = part { return roots[t] == s }
            return false
        }

        var hitsPerEntry: [[NSRange]] = Array(repeating: [], count: patterns.count)
        for t in tokens.indices {
            var candidates = wildcardFirst
            candidates += byFirstWord[tokens[t].word] ?? []
            if settings.matching == .sameRoot, roots[t] != tokens[t].word { candidates += byFirstWord[roots[t]] ?? [] }
            for e in Set(candidates) {
                let parts = patterns[e]!.parts
                guard t + parts.count <= tokens.count else { continue }
                let matched = parts.indices.allSatisfy { k in
                    partMatches(parts[k], t + k) && (k == 0 || tokens[t + k].joinedToPrevious)
                }
                if matched {
                    hitsPerEntry[e].append(NSUnionRange(tokens[t].range, tokens[t + parts.count - 1].range))
                }
            }
        }

        var hits: [WatchHit] = []
        var counts: [Report.WatchCount] = []
        for (e, entry) in settings.watchList.enumerated() where patterns[e] != nil {
            let count = hitsPerEntry[e].count
            let rate = tokens.isEmpty ? 0 : Double(count) * 1000 / Double(tokens.count)
            let flagged = entry.maxPerThousand.map { rate > $0 } ?? true
            counts.append(Report.WatchCount(pattern: entry.pattern, count: count, perThousand: rate,
                                            maxPerThousand: entry.maxPerThousand, flagged: flagged,
                                            ranges: hitsPerEntry[e]))
            if flagged { hits += hitsPerEntry[e].map { WatchHit(entry: e, range: $0) } }
        }
        hits.sort { $0.range.location < $1.range.location }
        return (hits, counts)
    }
}
