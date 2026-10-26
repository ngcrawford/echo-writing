import Foundation

public struct Token: Sendable, Equatable {
    /// UTF-16 range in the analyzed text, the same units Accessibility uses.
    public let range: NSRange
    /// Lowercased, curly apostrophes straightened, possessive `'s` removed when that setting is on.
    public let word: String
    public let isCapitalized: Bool
    /// First word of the text, of a paragraph, or after `.`, `!`, `?` or `…`.
    public let startsSentence: Bool
    public let paragraph: Int
    /// Only spaces separate this token from the previous one (no punctuation or line break). Phrases must be joined.
    public let joinedToPrevious: Bool
}

/// Splits text into words: runs of letters with internal apostrophes or hyphens (`don't`, `well-known`, `Sarah’s`).
/// Scans UTF-16 directly; NSRegularExpression plus per-match NSString calls was ~6× slower on a novel.
enum Tokenizer {
    /// Words that take `'s` as a contraction (`it's`, `she's`) rather than a possessive.
    private static let contractionBases: Set<String> = [
        "it", "he", "she", "that", "there", "here", "what", "who", "where", "when", "why", "how", "let",
        "this", "everyone", "everybody", "someone", "somebody", "nobody", "one",
    ]

    private static let apostrophe: UInt16 = 0x27, rightQuote: UInt16 = 0x2019
    private static let hyphen: UInt16 = 0x2D, unicodeHyphen: UInt16 = 0x2010

    static func tokenize(_ text: String, settings: EngineSettings) -> [Token] {
        let u = Array(text.utf16)
        let skip = urlRanges(u)
        var skipIndex = 0

        var tokens: [Token] = []
        tokens.reserveCapacity(u.count / 5)
        var previousEnd = 0
        var paragraph = 0
        var i = 0

        while i < u.count {
            guard isLetter(u[i]) else { i += 1; continue }
            let start = i
            i += 1
            while i < u.count {
                if isLetter(u[i]) {
                    i += 1
                } else if isJoiner(u[i]), i + 1 < u.count, isLetter(u[i + 1]) {
                    i += 2
                } else {
                    break
                }
            }
            let end = i
            while skipIndex < skip.count && skip[skipIndex].upperBound <= start { skipIndex += 1 }
            if skipIndex < skip.count && skip[skipIndex].lowerBound < end { continue }
            if (start > 0 && isDigit(u[start - 1])) || (end < u.count && isDigit(u[end])) { continue }

            // Classify the gap since the previous token.
            var newParagraph = false, sentenceEnd = false, joined = !tokens.isEmpty
            for k in previousEnd..<start {
                switch u[k] {
                case 0x0A, 0x0D, 0x2028, 0x2029: newParagraph = true; joined = false
                case 0x2E, 0x21, 0x3F, 0x2026: sentenceEnd = true; joined = false  // . ! ? …
                case 0x20, 0x09, 0xA0: break
                default: joined = false
                }
            }
            if newParagraph && !tokens.isEmpty { paragraph += 1 }
            let startsSentence = tokens.isEmpty || newParagraph || sentenceEnd
            previousEnd = end

            if settings.splitHyphenated {
                var partStart = start
                var first = true
                for k in start...end where k == end || u[k] == hyphen || u[k] == unicodeHyphen {
                    tokens.append(makeToken(u, partStart..<k, settings: settings, startsSentence: first && startsSentence,
                                            paragraph: paragraph, joined: first ? joined : true))
                    partStart = k + 1
                    first = false
                }
            } else {
                tokens.append(makeToken(u, start..<end, settings: settings, startsSentence: startsSentence,
                                        paragraph: paragraph, joined: joined))
            }
        }
        return tokens
    }

    private static func makeToken(_ u: [UInt16], _ r: Range<Int>, settings: EngineSettings, startsSentence: Bool,
                                  paragraph: Int, joined: Bool) -> Token {
        var word = lowercased(u[r])
        if settings.normalizePossessives, word.hasSuffix("'s") {
            let base = String(word.dropLast(2))
            if !contractionBases.contains(base) { word = base }
        }
        return Token(range: NSRange(location: r.lowerBound, length: r.count), word: word,
                     isCapitalized: isUppercase(u[r.lowerBound]), startsSentence: startsSentence,
                     paragraph: paragraph, joinedToPrevious: joined)
    }

    /// Lowercases and straightens `’` to `'`, with an ASCII fast path.
    private static func lowercased(_ s: ArraySlice<UInt16>) -> String {
        var ascii = true
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.count)
        for c in s {
            switch c {
            case 0x41...0x5A: bytes.append(UInt8(c + 0x20))
            case 0..<0x80: bytes.append(UInt8(c))
            case rightQuote: bytes.append(UInt8(apostrophe))
            default: ascii = false
            }
            if !ascii { break }
        }
        if ascii { return String(decoding: bytes, as: UTF8.self) }
        return String(decoding: s, as: UTF16.self).lowercased().replacingOccurrences(of: "’", with: "'")
    }

    private static func isLetter(_ c: UInt16) -> Bool {
        switch c {
        case 0x41...0x5A, 0x61...0x7A: return true
        case 0..<0xC0: return false
        case 0xD800...0xDFFF: return false  // surrogates: emoji and rare scripts aren't words here
        default:
            guard let s = Unicode.Scalar(c) else { return false }
            let p = s.properties
            return p.isAlphabetic || p.generalCategory == .nonspacingMark || p.generalCategory == .spacingMark
        }
    }

    private static func isUppercase(_ c: UInt16) -> Bool {
        if c < 0x80 { return c >= 0x41 && c <= 0x5A }
        return Unicode.Scalar(c)?.properties.isUppercase ?? false
    }

    private static func isJoiner(_ c: UInt16) -> Bool {
        c == apostrophe || c == rightQuote || c == hyphen || c == unicodeHyphen
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Whitespace-delimited stretches containing `://`, `www.` or `@`: URLs and email addresses.
    private static func urlRanges(_ u: [UInt16]) -> [Range<Int>] {
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 }
        var ranges: [Range<Int>] = []
        var i = 0
        while i < u.count {
            let c = u[i]
            let hit = c == 0x40  // @
                || (c == 0x3A && i + 2 < u.count && u[i + 1] == 0x2F && u[i + 2] == 0x2F)  // ://
                || ((c == 0x77 || c == 0x57) && i + 3 < u.count && u[i + 1] | 0x20 == 0x77 && u[i + 2] | 0x20 == 0x77
                    && u[i + 3] == 0x2E && (i == 0 || isSpace(u[i - 1])))  // www.
            guard hit else { i += 1; continue }
            var lo = i, hi = i
            while lo > 0 && !isSpace(u[lo - 1]) { lo -= 1 }
            while hi < u.count && !isSpace(u[hi]) { hi += 1 }
            if let last = ranges.last, last.upperBound >= lo { ranges[ranges.count - 1] = last.lowerBound..<hi } else { ranges.append(lo..<hi) }
            i = hi
        }
        return ranges
    }
}
