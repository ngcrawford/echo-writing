import Foundation
@testable import EchoEngine

/// The real bundled table, read from the source tree so tests run without SwiftPM resources.
let table: FrequencyTable = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/EchoEngine/Resources/zipf-en.tsv")
    return try! FrequencyTable(contentsOf: url)
}()

let analyzer = Analyzer(frequencies: table)

func analyze(_ text: String, _ configure: (inout EngineSettings) -> Void = { _ in }) -> AnalysisResult {
    var settings = EngineSettings()
    configure(&settings)
    return analyzer.analyze(text, settings: settings)
}

extension AnalysisResult {
    /// The text of every highlighted range, in order.
    func flagged(in text: String) -> [String] {
        matches.map { (text as NSString).substring(with: $0.range) }
    }

    /// The text of each watch-list hit, in order.
    func watched(in text: String) -> [String] {
        watchHits.map { (text as NSString).substring(with: $0.range) }
    }

    func group(_ word: String) -> RepeatGroup? {
        repeatGroups.first { $0.word == word }
    }
}

/// `n` filler words that are excluded and never repeat-flagged, for spacing occurrences apart.
func filler(_ n: Int) -> String {
    Array(repeating: "the", count: n).joined(separator: " ")
}
