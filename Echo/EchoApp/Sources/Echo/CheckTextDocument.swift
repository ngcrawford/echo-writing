import AppKit
import EchoEngine
import Observation

/// The Check Text window's text view, its analysis, and the highlights drawn into it (SPEC §5.6).
/// Text lives in memory only and is never saved.
@MainActor @Observable
final class CheckTextDocument: NSObject, NSTextViewDelegate {
    @ObservationIgnored let scrollView: NSScrollView
    @ObservationIgnored let textView: NSTextView

    private(set) var result: AnalysisResult?
    private(set) var analysisMilliseconds: Double?
    private(set) var isEmpty = true

    /// Words to skip in this text only, e.g. character names the heuristic missed.
    var ignoreList: [String] = [] {
        didSet { scheduleAnalysis(after: .zero) }
    }

    @ObservationIgnored var analyzer: Analyzer? {
        didSet { scheduleAnalysis(after: .zero) }
    }
    @ObservationIgnored var settings = EngineSettings() {
        didSet { if settings != oldValue { scheduleAnalysis(after: .zero) } }
    }
    @ObservationIgnored var highlightStyle = HighlightStyle.underline {
        didSet { if highlightStyle != oldValue, let result { applyHighlights(result) } }
    }

    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Bumped on every edit so results for older text are discarded.
    @ObservationIgnored private var generation = 0
    /// Next occurrence to show for each report row, keyed by row.
    @ObservationIgnored private var revealCursor: [String: Int] = [:]

    private static let font = NSFont(name: "Iowan Old Style", size: 17) ?? .systemFont(ofSize: 16)

    override init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init()

        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.font = Self.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: Self.font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor]
        textView.delegate = self
    }

    // MARK: Loading text

    func replaceText(with string: String) {
        textView.string = string
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        textChanged(delay: .zero)
    }

    /// Opens plain text, RTF, RTFD, Word (.docx) or HTML. Formatting is dropped.
    func open(url: URL) throws {
        let attributed = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        replaceText(with: attributed.string)
    }

    nonisolated func textDidChange(_ notification: Notification) {
        MainActor.assumeIsolated { textChanged(delay: .milliseconds(300)) }
    }

    private func textChanged(delay: Duration) {
        generation += 1
        isEmpty = textView.string.isEmpty
        revealCursor = [:]
        scheduleAnalysis(after: delay)
    }

    // MARK: Analysis

    private func scheduleAnalysis(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.analyze()
        }
    }

    private func analyze() async {
        guard let analyzer else { return }
        let text = textView.string
        var settings = settings
        settings.ignoreList += ignoreList
        let startGeneration = generation
        let start = ContinuousClock.now

        let result = await Task.detached(priority: .userInitiated) {
            analyzer.analyze(text, settings: settings)
        }.value

        guard !Task.isCancelled, startGeneration == generation else { return }
        let elapsed = ContinuousClock.now - start
        analysisMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        self.result = result
        applyHighlights(result)
    }

    private func applyHighlights(_ result: AnalysisResult) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        let explanations = Highlights.explanations(for: result, text: storage.string)
        storage.beginEditing()
        for key: NSAttributedString.Key in [.underlineStyle, .underlineColor, .backgroundColor, .toolTip] {
            storage.removeAttribute(key, range: full)
        }
        for (match, explanation) in zip(result.matches, explanations) where NSMaxRange(match.range) <= storage.length {
            let strength = Highlights.strength(for: match, in: result)
            let color = Highlights.color(for: match).withAlphaComponent(0.25 + 0.75 * strength)
            switch highlightStyle {
            case .underline:
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: color],
                                      range: match.range)
                if case .repeated = match.kind, strength >= 0.85 {   // uncommon and rare: tint too
                    storage.addAttribute(.backgroundColor, value: Highlights.repeatColor.withAlphaComponent(0.18 * strength),
                                         range: match.range)
                }
            case .background:
                storage.addAttribute(.backgroundColor, value: Highlights.color(for: match).withAlphaComponent(0.1 + 0.25 * strength),
                                     range: match.range)
            }
            storage.addAttribute(.toolTip, value: explanation, range: match.range)
        }
        storage.endEditing()
    }

    // MARK: Navigation

    /// Selects and flashes the next of `ranges` each time it's called with the same `key`.
    func reveal(_ ranges: [NSRange], key: String) {
        let valid = ranges.filter { NSMaxRange($0) <= (textView.string as NSString).length }
        guard !valid.isEmpty else { return }
        let index = (revealCursor[key].map { $0 + 1 } ?? 0) % valid.count
        revealCursor[key] = index
        let range = valid[index]
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }
}
