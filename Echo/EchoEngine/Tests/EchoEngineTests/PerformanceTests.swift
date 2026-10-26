import Foundation
import Testing
@testable import EchoEngine

/// Times a full analysis of a real manuscript. Set ECHO_BENCH_TEXT to a plain-text file to run it.
@Suite struct PerformanceTests {
    static let path = ProcessInfo.processInfo.environment["ECHO_BENCH_TEXT"]

    @Test(.enabled(if: path != nil)) func fullManuscript() throws {
        let text = try String(contentsOfFile: Self.path!, encoding: .utf8)
        let fresh = Analyzer(frequencies: table)
        var settings = EngineSettings()
        settings.watchList = DefaultLists.watchStarterPack.map { WatchEntry($0) }

        func time(_ label: String) -> AnalysisResult {
            let start = Date()
            let result = fresh.analyze(text, settings: settings)
            print(String(format: "%@: %.0f ms for %d words, %d repeat groups, %d watch hits", label,
                         Date().timeIntervalSince(start) * 1000, result.wordCount,
                         result.repeatGroups.count, result.watchHits.count))
            return result
        }
        _ = time("cold (empty root cache)")
        let warm = time("warm")
        print(warm.report.plainText())
    }
}
