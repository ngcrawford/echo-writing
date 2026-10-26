import EchoEngine
import SwiftUI

/// Live controls for the analysis. Changes are saved and re-check the text immediately.
/// Used in the Check Text sidebar (with `document`) and in Settings (without).
struct TuningPanel: View {
    @Environment(AppModel.self) private var model
    var document: CheckTextDocument?
    var includeLists = true

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Match", selection: $model.settings.matching) {
                    Text("Same root").tag(MatchingMode.sameRoot)
                    Text("Exact word").tag(MatchingMode.exact)
                }
                .help("Same root counts walk, walked and walking as one word")
                VStack(alignment: .leading) {
                    LabeledContent("Rarity sensitivity", value: String(format: "×%.2g", model.settings.sensitivity))
                    Slider(value: $model.settings.sensitivity, in: 0.5...3, step: 0.25)
                }
                .help("Stretches or shrinks every distance below together")
                if document != nil {   // Settings has it under General
                    Picker("Highlight", selection: $model.highlightStyle) {
                        Text("Underline").tag(HighlightStyle.underline)
                        Text("Background").tag(HighlightStyle.background)
                    }
                }
            }

            Section("Flag a repeat within…") {
                ForEach(Tier.allCases, id: \.self) { tier in
                    TierDistanceRow(tier: tier, setting: $model.settings.tiers[tier.rawValue],
                                    effective: model.settings.distance(for: tier))
                }
            }

            Section("Options") {
                Toggle("Skip character and place names", isOn: $model.settings.detectProperNouns)
                Toggle("Don't count repeats across paragraphs", isOn: $model.settings.resetAtParagraph)
                Toggle("Split hyphenated words", isOn: $model.settings.splitHyphenated)
                Toggle("Sarah's counts as Sarah", isOn: $model.settings.normalizePossessives)
            }

            if includeLists {
                WordListSections(document: document)
            }

            Section {
                Button("Restore default settings", role: .destructive) {
                    let watch = model.settings.watchList
                    model.settings = EngineSettings()
                    model.settings.watchList = watch
                    model.highlightStyle = .underline
                }
                .help("Resets everything except your watch list")
            }
        }
        .formStyle(.grouped)
    }
}

/// Watch list, per-text ignore list and exclude list, as Form sections.
struct WordListSections: View {
    @Environment(AppModel.self) private var model
    var document: CheckTextDocument?

    var body: some View {
        @Bindable var model = model
        Section {
            ListEditor(entries: watchListLines, placeholder: "just\nbegan to\n*ly\nsuddenly 1/1000")
            Button("Add starter pack") {
                let existing = Set(model.settings.watchList.map(\.pattern))
                model.settings.watchList += DefaultLists.watchStarterPack.filter { !existing.contains($0) }
                    .map { WatchEntry($0) }
            }
        } header: {
            Text("Watch list")
        } footer: {
            Text("One word or phrase per line. * matches any ending or beginning. Add “3/1000” to flag only above 3 per 1,000 words.")
                .font(.caption).foregroundStyle(.secondary)
        }

        if let document {
            @Bindable var document = document
            Section {
                ListEditor(entries: $document.ignoreList, placeholder: "Elara\nVell")
            } header: {
                Text("Ignore in this text")
            } footer: {
                Text("Names or words to skip. Cleared when Echo quits.").font(.caption).foregroundStyle(.secondary)
            }
        } else if !model.live.documentIgnores.isEmpty {
            Section {
                LabeledContent("Ignored in documents",
                               value: "\(model.live.documentIgnores.values.map(\.count).reduce(0, +)) words")
                Button("Clear") { model.live.clearDocumentIgnores() }
            } footer: {
                Text("Words you chose “Ignore in document” for, in Scrivener projects and Vellum books.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section {
            DisclosureGroup("Exclude list (\(model.settings.excludeList.count) words)") {
                ListEditor(entries: $model.settings.excludeList, placeholder: "")
                    .frame(minHeight: 160)
            }
        } footer: {
            Text("Never flagged as repeats, but still counted toward distance.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Watch entries as editable lines: "just" or "just 3/1000".
    private var watchListLines: Binding<[String]> {
        Binding {
            model.settings.watchList.map { entry in
                entry.maxPerThousand.map { "\(entry.pattern) \(String(format: "%g", $0))/1000" } ?? entry.pattern
            }
        } set: { lines in
            model.settings.watchList = lines.map { line in
                var words = line.split(separator: " ")
                if let last = words.last, last.hasSuffix("/1000"), let rate = Double(last.dropLast(5)), words.count > 1 {
                    words.removeLast()
                    return WatchEntry(words.joined(separator: " "), maxPerThousand: rate)
                }
                return WatchEntry(line)
            }
        }
    }
}

private struct TierDistanceRow: View {
    let tier: Tier
    @Binding var setting: TierSetting
    let effective: Int

    var body: some View {
        LabeledContent {
            HStack {
                TextField("", value: $setting.distance, format: .number)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("words")
            }
        } label: {
            VStack(alignment: .leading) {
                Text(tier.label.capitalized)
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var caption: String {
        let examples = ["the, said, know", "walked, door", "glanced, shoulder", "cerulean, gossamer", "susurrus, crepuscular"]
        let scaled = effective != setting.distance ? " · now \(effective) with sensitivity" : ""
        return examples[tier.rawValue] + scaled
    }
}

/// A plain multi-line editor for a word list, one entry per line. Blank lines are dropped.
private struct ListEditor: View {
    @Binding var entries: [String]
    let placeholder: String
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .frame(minHeight: 90)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(.body.monospaced()).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .onAppear { text = entries.joined(separator: "\n") }
            .onChange(of: text) {
                let parsed = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parsed != entries { entries = parsed }
            }
            .onChange(of: entries) {
                let parsed = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if parsed != entries { text = entries.joined(separator: "\n") }
            }
    }
}
