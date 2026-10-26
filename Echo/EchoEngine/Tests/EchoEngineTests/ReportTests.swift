import Foundation
import Testing
@testable import EchoEngine

@Suite struct ReportTests {
    @Test func countsTopWordsWatchRatesAndTiers() {
        let text = "The door opened. The door closed. A cerulean door. \(filler(100)) cerulean"
        let result = analyze(text) { $0.watchList = [WatchEntry("door")] }
        let report = result.report

        #expect(report.wordCount == result.tokens.count)
        #expect(report.topWords.map(\.word) == ["door", "cerulean"])
        #expect(report.topWords[0].count == 3 && report.topWords[0].tier == .common)
        #expect(report.repeatGroupsByTier[.common] == 1)
        #expect(report.repeatGroupsByTier[.uncommon] == 1)
        #expect(report.watch.first?.count == 3)
        #expect(report.topWords[0].ranges.map { (text as NSString).substring(with: $0) } == ["door", "door", "door"])
        #expect(report.watch.first?.ranges.count == 3)

        let copy = report.plainText()
        #expect(copy.contains("door: 3× (common)"))
        #expect(copy.contains("uncommon: 1"))
    }

    @Test func matchesAreSortedByLocation() {
        let result = analyze("Just the door. Just the door.") { $0.watchList = [WatchEntry("just")] }
        let locations = result.matches.map(\.range.location)
        #expect(locations == locations.sorted())
        #expect(result.matches.count == 4)
    }
}
