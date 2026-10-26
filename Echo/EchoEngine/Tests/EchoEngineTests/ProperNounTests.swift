import Foundation
import Testing
@testable import EchoEngine

@Suite struct ProperNounTests {
    @Test func namesCapitalizedMidSentenceAreSkipped() {
        let text = "Elara ran. Then Elara stopped, and Sarah’s dog barked at Elara."
        let result = analyze(text)
        #expect(result.properNouns.isSuperset(of: ["elara", "sarah"]))
        #expect(result.repeatGroups.isEmpty)
    }

    @Test func wordsOnlyCapitalizedAtSentenceStartAreNotNames() {
        let text = "Suddenly it moved. Suddenly it stopped."
        let result = analyze(text)
        #expect(!result.properNouns.contains("suddenly"))
        #expect(result.group("suddenly") != nil)
    }

    @Test func wordsAlsoUsedLowercaseAreNotNames() {
        // "Will" as a name and "will" as a verb: not always capitalized, so still checked (but "will" is excluded).
        let result = analyze("Then Hope arrived, and hope faded.")
        #expect(!result.properNouns.contains("hope"))
        #expect(result.group("hope")?.ranges.count == 2)
    }

    @Test func canBeTurnedOff() {
        let result = analyze("Then Elara ran and Elara hid.") { $0.detectProperNouns = false }
        #expect(result.group("elara")?.ranges.count == 2)
    }
}
