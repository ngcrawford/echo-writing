import Foundation
import Testing
@testable import EchoEngine

@Suite struct RepeatTests {
    @Test func tiersMatchSpecExamples() {
        let s = EngineSettings()
        func tier(_ w: String) -> Tier { s.tier(forZipf: table.zipf(w)) }
        #expect(tier("the") == .veryCommon)
        #expect(tier("walked") == .common)
        #expect(tier("door") == .common)
        #expect(tier("glanced") == .moderate)
        #expect(tier("cerulean") == .uncommon)
        #expect(tier("gossamer") == .uncommon)
        #expect(tier("crepuscular") == .rare)
        #expect(tier("susurrus") == .rare)
    }

    @Test func flagsWithinTierDistanceOnly() {
        // "door" is common: limit 40 words.
        let near = analyze("The door \(filler(30)) door")
        #expect(near.group("door")?.positions == [1, 32])
        #expect(near.group("door")?.gap(before: 1) == 31)
        #expect(analyze("The door \(filler(45)) door").repeatGroups.isEmpty)

        // "cerulean" is uncommon: limit 500, so 300 words apart still counts.
        #expect(analyze("A cerulean sky \(filler(300)) cerulean").group("cerulean")?.limit == 500)
    }

    @Test func excludedWordsCountTowardDistanceButAreNeverFlagged() {
        let result = analyze("door \(filler(45)) door")
        #expect(result.repeatGroups.isEmpty)
        #expect(result.matches.isEmpty)
    }

    @Test func sameRootGroupsWordForms() {
        let text = "She walked in. He walks out, walking slowly."
        let result = analyze(text)
        #expect(result.group("walk")?.ranges.count == 3)
        #expect(result.flagged(in: text) == ["walked", "walks", "walking"])
        #expect(analyze(text) { $0.matching = .exact }.repeatGroups.isEmpty)
    }

    @Test func excludeListAppliesToRoots() {
        // "was" and "were" share the excluded root "be".
        #expect(analyze("It was cold and they were tired").repeatGroups.isEmpty)
    }

    @Test func chainsBecomeOneGroup() {
        // Each "door" is within 40 of the next, though first and last are 60 apart.
        let result = analyze("door \(filler(29)) door \(filler(29)) door \(filler(60)) door")
        #expect(result.repeatGroups.count == 1)
        #expect(result.group("door")?.ranges.count == 3)
    }

    @Test func sensitivityAndOverridesChangeTheLimit() {
        let text = "door \(filler(60)) door"
        #expect(analyze(text).repeatGroups.isEmpty)
        #expect(analyze(text) { $0.sensitivity = 2 }.group("door")?.limit == 80)
        #expect(analyze(text) { $0.distanceOverrides = ["door": 100] }.group("door")?.limit == 100)
    }

    @Test func paragraphResetIsOptional() {
        let text = "The door creaked.\nThe door opened."
        #expect(analyze(text).repeatGroups.count == 1)
        #expect(analyze(text) { $0.resetAtParagraph = true }.repeatGroups.isEmpty)
    }

    @Test func ignoreListSkipsWords() {
        let text = "The door, the door."
        #expect(analyze(text) { $0.ignoreList = ["door"] }.repeatGroups.isEmpty)
        #expect(analyze(text) { $0.ignoreList = ["do*"] }.repeatGroups.isEmpty)
    }
}
