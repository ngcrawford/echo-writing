import Foundation
import Testing
@testable import EchoEngine

@Suite struct WatchListTests {
    @Test func flagsEveryOccurrenceRegardlessOfDistance() {
        let text = "It was just fine. \(filler(2000)) Just go."
        let result = analyze(text) { $0.watchList = [WatchEntry("just")] }
        #expect(result.watchHits.count == 2)
        #expect(result.watched(in: text) == ["just", "Just"])
    }

    @Test func watchTakesPriorityOverExclude() {
        // "very" isn't excluded by default, but "that" is.
        let result = analyze("I knew that. That was all.") { $0.watchList = [WatchEntry("that")] }
        #expect(result.watchHits.count == 2)
    }

    @Test func phrasesMustBeAdjacentWithinASentence() {
        let text = "She began to cry. He began. To his surprise, they began  to laugh."
        let result = analyze(text) { $0.watchList = [WatchEntry("began to")] }
        #expect(result.watched(in: text) == ["began to", "began  to"])
    }

    @Test func wildcards() {
        let text = "He quickly looked, then looking away, he slowly overlooked it."
        let adverbs = analyze(text) { $0.watchList = [WatchEntry("*ly")] }
        #expect(adverbs.watched(in: text) == ["quickly", "slowly"])
        let looks = analyze(text) { $0.watchList = [WatchEntry("look*")] }
        #expect(looks.watched(in: text) == ["looked", "looking"])
    }

    @Test func sameRootCatchesOtherForms() {
        let text = "She realized it. He realizes it."
        #expect(analyze(text) { $0.watchList = [WatchEntry("realize")] }.watchHits.count == 2)
        #expect(analyze(text) { $0.watchList = [WatchEntry("realize")]; $0.matching = .exact }.watchHits.isEmpty)
    }

    @Test func thresholdSuppressesUntilExceeded() {
        // 2 hits in 10 words = 200 per 1,000.
        let text = "Just one thing, just one more thing and then go."
        let under = analyze(text) { $0.watchList = [WatchEntry("just", maxPerThousand: 250)] }
        #expect(under.watchHits.isEmpty)
        #expect(under.report.watch.first?.flagged == false)
        #expect(under.report.watch.first?.count == 2)
        let over = analyze(text) { $0.watchList = [WatchEntry("just", maxPerThousand: 150)] }
        #expect(over.watchHits.count == 2)
    }

    @Test func starterPackParses() {
        let entries = DefaultLists.watchStarterPack.map { WatchEntry($0) }
        #expect(entries.allSatisfy { WordPattern($0.pattern) != nil })
    }
}
