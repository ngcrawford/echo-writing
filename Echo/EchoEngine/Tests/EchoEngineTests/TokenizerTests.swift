import Foundation
import Testing
@testable import EchoEngine

@Suite struct TokenizerTests {
    func words(_ text: String, _ configure: (inout EngineSettings) -> Void = { _ in }) -> [String] {
        var settings = EngineSettings()
        configure(&settings)
        return Tokenizer.tokenize(text, settings: settings).map(\.word)
    }

    @Test func lowercasesAndKeepsContractionsWhole() {
        #expect(words("She didn’t go. The DOOR") == ["she", "didn't", "go", "the", "door"])
    }

    @Test func normalizesPossessivesButNotContractions() {
        #expect(words("Sarah’s coat. It's late, she's here.") == ["sarah", "coat", "it's", "late", "she's", "here"])
        #expect(words("Sarah's coat") { $0.normalizePossessives = false } == ["sarah's", "coat"])
    }

    @Test func hyphenatedWordsAreOneTokenUnlessSplit() {
        #expect(words("a well-known face") == ["a", "well-known", "face"])
        #expect(words("a well-known face") { $0.splitHyphenated = true } == ["a", "well", "known", "face"])
    }

    @Test func ignoresNumbersAndURLs() {
        #expect(words("On the 3rd day, 42 men read https://example.com/page and mail@example.com") ==
            ["on", "the", "day", "men", "read", "and"])
    }

    @Test func rangesAreUTF16() {
        let text = "Café — “naïve” 🙂 word"
        let tokens = Tokenizer.tokenize(text, settings: EngineSettings())
        #expect(tokens.map { (text as NSString).substring(with: $0.range) } == ["Café", "naïve", "word"])
    }

    @Test func tracksSentencesParagraphsAndJoins() {
        let tokens = Tokenizer.tokenize("He began to run. “Stop,” Elara said.\n\nNext day", settings: EngineSettings())
        #expect(tokens.map(\.startsSentence) == [true, false, false, false, true, false, false, true, false])
        #expect(tokens.map(\.paragraph) == [0, 0, 0, 0, 0, 0, 0, 1, 1])
        #expect(tokens.map(\.joinedToPrevious) == [false, true, true, true, false, false, true, false, true])
        #expect(tokens[5].isCapitalized && !tokens[6].isCapitalized)
    }
}

#if SWIFT_PACKAGE
@Test func bundledTableLoads() throws {
    let bundled = try FrequencyTable.bundled()
    #expect(bundled.zipf("cerulean") == table.zipf("cerulean"))
}
#endif
