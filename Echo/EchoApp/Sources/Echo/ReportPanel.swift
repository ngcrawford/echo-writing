import EchoEngine
import SwiftUI

/// Summary report (SPEC §5.6). Clicking a row selects its next occurrence in the text.
struct ReportPanel: View {
    let document: CheckTextDocument

    var body: some View {
        if let result = document.result, !document.isEmpty {
            List {
                summary(result)
                topWords(result.report)
                watchList(result.report)
                tiers(result)
            }
            .listStyle(.sidebar)
        } else {
            ContentUnavailableView("No text yet", systemImage: "doc.text",
                                   description: Text("The report appears once there's text to check."))
        }
    }

    private func summary(_ result: AnalysisResult) -> some View {
        Section {
            LabeledContent("Words", value: result.wordCount.formatted())
            LabeledContent("Close repeats", value: result.repeatGroups.count.formatted())
            LabeledContent("Watch-list hits", value: result.watchHits.count.formatted())
            if let ms = document.analysisMilliseconds {
                LabeledContent("Checked in", value: "\(Int(ms.rounded())) ms")
            }
        }
    }

    private func topWords(_ report: Report) -> some View {
        Section("Most used words") {
            ForEach(report.topWords, id: \.word) { w in
                row(key: "word:\(w.word)", ranges: w.ranges) {
                    Text(document.writtenForm(at: w.ranges, fallback: w.word))
                    Text(w.tier.label).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if w.repeatGroups > 0 {
                        Text("\(w.repeatGroups) close").font(.caption).foregroundStyle(.orange)
                    }
                    Text("\(w.count)×").monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func watchList(_ report: Report) -> some View {
        if !report.watch.isEmpty {
            Section("Watch list (per 1,000 words)") {
                ForEach(Array(report.watch.enumerated()), id: \.offset) { _, w in
                    row(key: "watch:\(w.pattern)", ranges: w.ranges) {
                        Text(w.pattern).foregroundStyle(w.flagged ? .primary : .secondary)
                        Spacer()
                        Text("\(w.count)×").monospacedDigit()
                        Text(String(format: "%.1f", w.perThousand)).monospacedDigit()
                            .foregroundStyle(w.flagged ? .blue : .secondary)
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                    .help(w.maxPerThousand.map { String(format: "Flagged above %.1f per 1,000 words", $0) } ?? "Always flagged")
                }
            }
        }
    }

    private func tiers(_ result: AnalysisResult) -> some View {
        Section("Close repeats by rarity") {
            ForEach(Tier.allCases, id: \.self) { tier in
                let groups = result.repeatGroups.filter { $0.tier == tier }
                row(key: "tier:\(tier.rawValue)", ranges: groups.map { $0.ranges[0] }) {
                    Text(tier.label.capitalized)
                    Spacer()
                    Text(groups.count.formatted()).monospacedDigit()
                }
            }
        }
    }

    private func row<Content: View>(key: String, ranges: [NSRange], @ViewBuilder content: () -> Content) -> some View {
        Button {
            document.reveal(ranges, key: key)
        } label: {
            HStack(spacing: 6, content: content).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(ranges.isEmpty)
    }
}
