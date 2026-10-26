import Foundation

/// How occurrences of a word are grouped when looking for repeats (SPEC §4.2).
public enum MatchingMode: String, Codable, Sendable {
    /// `walk` and `walked` are different words.
    case exact
    /// `walk`, `walked` and `walking` count as the same word.
    case sameRoot
}

/// Rarity tiers, most common first (SPEC §4.3).
public enum Tier: Int, Codable, Sendable, CaseIterable, Comparable {
    case veryCommon, common, moderate, uncommon, rare

    public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .veryCommon: "very common"
        case .common: "common"
        case .moderate: "moderate"
        case .uncommon: "uncommon"
        case .rare: "rare"
        }
    }
}

public struct TierSetting: Codable, Sendable, Equatable {
    /// Lowest Zipf score in this tier. Ignored for `.rare`, which takes everything below `.uncommon`.
    public var minZipf: Double
    /// Largest gap, in words, at which a repeat is flagged (before the sensitivity multiplier).
    public var distance: Int

    public init(minZipf: Double, distance: Int) {
        self.minZipf = minZipf
        self.distance = distance
    }
}

/// A watch-list word or phrase. Supports `*` at either end of a word (`*ly`, `look*`).
public struct WatchEntry: Codable, Sendable, Equatable {
    public var pattern: String
    /// Only flag when the entry occurs more than this many times per 1,000 words. `nil` flags every occurrence.
    public var maxPerThousand: Double?

    public init(_ pattern: String, maxPerThousand: Double? = nil) {
        self.pattern = pattern
        self.maxPerThousand = maxPerThousand
    }
}

public struct EngineSettings: Codable, Sendable, Equatable {
    public var matching: MatchingMode = .sameRoot
    /// One entry per `Tier`, indexed by `Tier.rawValue`.
    public var tiers: [TierSetting] = EngineSettings.defaultTiers
    /// Scales every tier's distance together (the "Rarity sensitivity" slider, ×0.5 to ×3).
    public var sensitivity: Double = 1.0
    /// Per-word distance that replaces the tier distance, keyed by lowercased word or root.
    public var distanceOverrides: [String: Int] = [:]
    public var excludeList: [String] = DefaultLists.exclude
    public var watchList: [WatchEntry] = []
    /// Per-document words to skip, e.g. names the proper-noun heuristic missed.
    public var ignoreList: [String] = []
    public var detectProperNouns = true
    public var resetAtParagraph = false
    /// `Sarah's` → `sarah`.
    public var normalizePossessives = true
    /// `well-known` → `well`, `known`.
    public var splitHyphenated = false

    /// Thresholds are calibrated to wordfreq Zipf scores: *walked* 4.7, *glanced* 3.2, *cerulean* 2.3, *crepuscular* 1.9.
    public static let defaultTiers: [TierSetting] = [
        TierSetting(minZipf: 5.5, distance: 15),
        TierSetting(minZipf: 4.5, distance: 40),
        TierSetting(minZipf: 3.0, distance: 150),
        TierSetting(minZipf: 2.0, distance: 500),
        TierSetting(minZipf: 0, distance: 1500),
    ]

    public init() {}

    public func tier(forZipf zipf: Double) -> Tier {
        for tier in Tier.allCases where tier != .rare && zipf >= tiers[tier.rawValue].minZipf {
            return tier
        }
        return .rare
    }

    public func distance(for tier: Tier) -> Int {
        max(1, Int((Double(tiers[tier.rawValue].distance) * sensitivity).rounded()))
    }
}
