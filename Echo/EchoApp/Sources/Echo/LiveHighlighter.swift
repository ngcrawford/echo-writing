import AppKit
import ApplicationServices
import EchoEngine
import Observation

/// Highlights repeats directly in the frontmost writing app (SPEC §5.2, §6).
///
/// Follows the frontmost app; when it's on the allow list, finds its document editor, reads the whole text
/// through Accessibility, analyzes it off the main thread, and draws the visible matches in an overlay. Text
/// changes, selection changes, scrolling, and window moves all trigger a redraw; a light 0.1 s poll catches
/// scrolling that the host app doesn't report.
@MainActor @Observable
final class LiveHighlighter {
    /// A match in the current text. Ranges shift on every edit so highlights stay put until the next analysis.
    private struct Tracked: Sendable {
        var range: NSRange
        let isRepeat: Bool
        let strength: CGFloat
        let tip: String
        /// The word as written, lowercased, plus its root when different ("illustrations", "illustration"):
        /// what "Exclude" and "Ignore in document" add, so every form of the word is covered.
        let word: String
        let forms: [String]
        /// Which repeat group it belongs to, so "Show other" can find the rest.
        let group: Int?
    }

    enum Status: Equatable {
        case off
        case needsPermission
        case idle
        case noDocument(app: String)
        case active(app: String, repeats: Int, watch: Int)
    }

    private(set) var status = Status.off

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored var analyzer: Analyzer? {
        didSet { scheduleAnalysis(after: .zero) }
    }
    @ObservationIgnored var settings = EngineSettings() {
        didSet { if settings != oldValue { scheduleAnalysis(after: .zero) } }
    }
    @ObservationIgnored var background = false {
        didSet { if background != oldValue { scheduleGeometry() } }
    }
    /// Enabled apps, bundle ID → name (SPEC §5.4).
    @ObservationIgnored var apps: [String: String] = [:] {
        didSet {
            guard apps != oldValue, isEnabled, status != .needsPermission else { return }
            detach()
            follow(NSWorkspace.shared.frontmostApplication)
        }
    }
    /// Called by the bubble's "Exclude" button with the word to add to the exclude list.
    @ObservationIgnored var onExclude: ((String) -> Void)?

    /// Words ignored per document (SPEC §5.3), keyed by app and window document. Saved between launches.
    private(set) var documentIgnores: [String: [String]] =
        UserDefaults.standard.dictionary(forKey: "documentIgnores") as? [String: [String]] ?? [:] {
        didSet { UserDefaults.standard.set(documentIgnores, forKey: "documentIgnores") }
    }

    /// The full text of the document being highlighted, for "Check Text" (SPEC §5.6).
    func currentDocumentText() -> String? {
        editor?.string(kAXValueAttribute)
    }

    func clearDocumentIgnores() {
        documentIgnores = [:]
        scheduleAnalysis(after: .zero)
    }

    // Host app and editor
    @ObservationIgnored private var appName = ""
    @ObservationIgnored private var bundleID = ""
    /// Identifies the open document (Scrivener project, Vellum book) for "Ignore in this document".
    @ObservationIgnored private var documentKey = ""
    @ObservationIgnored private var pid: pid_t = 0
    @ObservationIgnored private var appElement: AXUIElement?
    @ObservationIgnored private var observer: AXObserver?
    @ObservationIgnored private var editor: AXUIElement?
    @ObservationIgnored private var editorWindow: AXUIElement?
    @ObservationIgnored private var scrollArea: AXUIElement?
    @ObservationIgnored private var scrollBar: AXUIElement?

    // Analysis
    @ObservationIgnored private var textLength = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingAnalysis: Task<Void, Never>?
    /// Matches in the current text. Shifted on every edit so highlights stay put while the next analysis runs.
    @ObservationIgnored private var tracked: [Tracked] = []
    /// Single occurrences dismissed with "Ignore here", shifted with edits like `tracked`.
    @ObservationIgnored private var ignoredHere: [NSRange] = []

    // Drawing
    @ObservationIgnored private let overlay = OverlayWindow()
    @ObservationIgnored private let bubble = HoverBubble()
    @ObservationIgnored private var geometryScheduled = false
    @ObservationIgnored private var lastGeometry = ContinuousClock.now
    @ObservationIgnored private var lastLayout: (position: CGPoint, clip: CGRect)?
    @ObservationIgnored private var pollTimer: Timer?
    /// Polls run every 0.1 s while the user is active, every 0.5 s after 2 s of quiet (idle CPU ~0).
    @ObservationIgnored private var lastActivity = ContinuousClock.now
    @ObservationIgnored private var pollTick = 0
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var eventMonitor: Any?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    // MARK: Lifecycle

    private func start() {
        guard Accessibility.isTrusted else {
            status = .needsPermission
            // Start by itself as soon as access is granted in System Settings.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in
                    guard let self, Accessibility.isTrusted else { return }
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    if self.isEnabled { self.start() }
                }
            }
            return
        }
        status = .idle
        // A busy host app (laying out a long manuscript, say) shouldn't freeze Echo for the default 6 s per query.
        // Set on the system-wide element, this applies to every element Echo talks to.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.follow(app) }
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .scrollWheel, .leftMouseDown]) { [weak self] event in
            let type = event.type
            MainActor.assumeIsolated { self?.handleMouse(type) }
        }
        pollTimer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.poll() }
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
        follow(NSWorkspace.shared.frontmostApplication)
    }

    private func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        detach()
        status = .off
    }

    /// Called when the user grants permission from the menu, so the status updates without waiting.
    func recheckPermission() {
        if isEnabled, status == .needsPermission, Accessibility.isTrusted {
            permissionTimer?.invalidate()
            permissionTimer = nil
            start()
        }
    }

    // MARK: Following the frontmost app

    private func follow(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != pid else { return }
        detach()
        guard let id = app.bundleIdentifier, let name = apps[id] else { return }

        appName = name
        bundleID = id
        pid = app.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        appElement = element

        var observer: AXObserver?
        guard AXObserverCreate(pid, axCallback, &observer) == .success, let observer else { return }
        self.observer = observer
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                     kAXWindowMovedNotification, kAXWindowResizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        locateEditor()
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        pid = 0
        setEditor(nil)
        if isEnabled, Accessibility.isTrusted { status = .idle }
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    fileprivate func handle(_ notification: String, element: AXUIElement) {
        lastActivity = .now
        switch notification {
        case kAXValueChangedNotification where element.isSame(as: editor):
            textChanged()
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification,
             kAXWindowMovedNotification, kAXWindowResizedNotification:
            scheduleGeometry()
        default:
            // Focus moved, a window changed, or something was destroyed (maybe our editor).
            locateEditor()
        }
    }

    // MARK: Finding the editor

    private func locateEditor() {
        guard let appElement else { return }
        let window = appElement.element(kAXFocusedWindowAttribute)
        var found: AXUIElement?
        if let focused = appElement.element(kAXFocusedUIElementAttribute), Accessibility.isEditor(focused),
           focused.element(kAXWindowAttribute).map({ $0.isSame(as: window) }) == true {
            found = focused   // (focus can briefly still report the previous window's editor after a window switch)
        } else if let editor, editor.frame != nil, editor.element(kAXWindowAttribute).map({ $0.isSame(as: window) }) == true {
            found = editor   // Focus moved to the binder or inspector: keep highlighting the same editor.
        } else if let window {
            found = Accessibility.largestTextArea(in: window)
        }
        if let found, found.isSame(as: editor) {
            scheduleGeometry()
        } else {
            setEditor(found)
        }
    }

    private func setEditor(_ element: AXUIElement?) {
        if let observer {
            if let editor {
                AXObserverRemoveNotification(observer, editor, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, editor, kAXSelectedTextChangedNotification as CFString)
            }
            if let scrollBar {
                AXObserverRemoveNotification(observer, scrollBar, kAXValueChangedNotification as CFString)
            }
        }
        editor = element
        editorWindow = element?.element(kAXWindowAttribute)
        scrollArea = element.flatMap(Accessibility.scrollArea(containing:))
        scrollBar = scrollArea?.element(kAXVerticalScrollBarAttribute)
        tracked = []
        ignoredHere = []
        textLength = 0
        lastLayout = nil
        overlay.hide()
        bubble.hide()
        pendingAnalysis?.cancel()
        generation += 1

        guard let element, let observer else {
            if appElement != nil { status = .noDocument(app: appName) }
            return
        }
        AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXSelectedTextChangedNotification as CFString, refcon)
        if let scrollBar {
            AXObserverAddNotification(observer, scrollBar, kAXValueChangedNotification as CFString, refcon)
        }
        textLength = element.int(kAXNumberOfCharactersAttribute) ?? 0
        let document = editorWindow.flatMap { $0.string(kAXDocumentAttribute) ?? $0.string(kAXTitleAttribute) } ?? ""
        documentKey = "\(bundleID) \(document)"
        status = .active(app: appName, repeats: 0, watch: 0)
        scheduleAnalysis(after: .zero)
    }

    // MARK: Analysis

    private func textChanged() {
        guard let editor else { return }
        let newLength = editor.int(kAXNumberOfCharactersAttribute) ?? 0
        let delta = newLength - textLength
        textLength = newLength
        generation += 1   // an analysis already running is for the old text
        if abs(delta) > 1000 {
            // Probably a different document (Scrivener reuses the editor): don't shift old highlights onto it.
            tracked = []
            ignoredHere = []
            scheduleAnalysis(after: .zero)
        } else {
            if delta != 0, let caret = editor.range(kAXSelectedTextRangeAttribute)?.location {
                shiftTracked(editStart: caret - max(delta, 0), delta: delta)
            }
            scheduleAnalysis(after: .milliseconds(300))
        }
        bubble.hide()
        scheduleGeometry()
    }

    /// Keeps highlights attached to their words after an edit at `editStart`. Words touching the edit are
    /// dropped until the next analysis.
    private func shiftTracked(editStart: Int, delta: Int) {
        let editEnd = editStart + max(-delta, 0)
        func shift(_ range: NSRange) -> NSRange? {
            if NSMaxRange(range) < editStart { return range }
            if range.location > editEnd { return NSRange(location: range.location + delta, length: range.length) }
            return nil
        }
        tracked = tracked.compactMap { item in
            guard let range = shift(item.range) else { return nil }
            var item = item
            item.range = range
            return item
        }
        ignoredHere = ignoredHere.compactMap(shift)
    }

    private func scheduleAnalysis(after delay: Duration) {
        pendingAnalysis?.cancel()
        guard editor != nil, analyzer != nil else { return }
        pendingAnalysis = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.analyze()
        }
    }

    private func analyze() async {
        guard let analyzer, let editor, let text = editor.string(kAXValueAttribute) else { return }
        generation += 1
        let startGeneration = generation
        var settings = settings
        settings.ignoreList += documentIgnores[documentKey] ?? []
        let ignored = Set(ignoredHere.map(\.location))
        // Everything up to the finished highlight list runs off the main thread: ~200 ms for a 130k-word manuscript.
        let (result, items) = await Task.detached(priority: .userInitiated) {
            let result = analyzer.analyze(text, settings: settings)
            return (result, Self.trackedMatches(result, text: text, ignored: ignored))
        }.value
        guard !Task.isCancelled, startGeneration == generation, editor.isSame(as: self.editor) else { return }

        textLength = (text as NSString).length
        tracked = items
        status = .active(app: appName, repeats: result.repeatGroups.count, watch: result.watchHits.count)
        scheduleGeometry()
    }

    nonisolated private static func trackedMatches(_ result: AnalysisResult, text: String, ignored: Set<Int>) -> [Tracked] {
        let ns = text as NSString
        return zip(result.matches, Highlights.explanations(for: result, text: text)).compactMap { match, tip in
            guard !ignored.contains(match.range.location) else { return nil }
            let word = ns.substring(with: match.range).lowercased()
            var forms = [word]
            var group: Int?
            if case .repeated(let g, _) = match.kind {
                group = g
                if result.repeatGroups[g].word != word { forms.append(result.repeatGroups[g].word) }
            }
            return Tracked(range: match.range, isRepeat: group != nil, strength: Highlights.strength(for: match, in: result),
                           tip: tip, word: word, forms: forms, group: group)
        }
    }

    // MARK: Geometry

    /// Coalesces redraw requests, at most ~30 a second. Every redraw makes the host app answer Accessibility
    /// queries on its own main thread, so redrawing on every scroll event would slow its scrolling.
    private func scheduleGeometry(after minimum: Duration = .zero) {
        guard !geometryScheduled else { return }
        geometryScheduled = true
        let wait = max(minimum, .milliseconds(33) - (ContinuousClock.now - lastGeometry))
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self else { return }
            self.geometryScheduled = false
            self.lastGeometry = .now
            self.updateGeometry()
        }
    }

    private func updateGeometry() {
        let deadline = ContinuousClock.now + .milliseconds(150)
        guard let editor, let layout = currentLayout(), shouldShow() else {
            overlay.hide()
            bubble.hide()
            return
        }
        lastLayout = layout
        let visible = editor.range(kAXVisibleCharacterRangeAttribute) ?? NSRange(location: 0, length: textLength)
        var marks: [OverlayMark] = []
        // Whether each line is really showing, keyed by its y. Headers and toolbars can float over the edges of
        // the scroll area (Vellum's chapter header does), hiding lines that are inside the clip; only lines near
        // the edges are checked.
        var lineShowing: [Int: Bool] = [:]
        let edgeBand: CGFloat = 150
        for (id, item) in tracked.enumerated() where NSIntersectionRange(item.range, visible).length > 0 || visible.length == 0 {
            if ContinuousClock.now > deadline {
                // The app is slow to answer (busy laying out a long document): keep what's drawn and try again.
                scheduleGeometry(after: .milliseconds(250))
                return
            }
            guard let rect = editor.bounds(for: item.range), rect.width > 0, rect.intersects(layout.clip) else { continue }
            if rect.midY < layout.clip.minY + edgeBand || rect.midY > layout.clip.maxY - edgeBand {
                let line = Int(rect.midY.rounded())
                if lineShowing[line] == nil {
                    lineShowing[line] = isEditorShowing(at: CGPoint(x: rect.midX, y: rect.midY), editor: editor)
                }
                guard lineShowing[line] == true else { continue }
            }
            marks.append(OverlayMark(id: id, rect: rect, color: item.isRepeat ? Highlights.repeatColor : Highlights.watchColor,
                                     wavy: item.isRepeat, strength: item.strength))
        }
        overlay.show(marks, clip: layout.clip, background: background)
    }

    /// Whether the editor itself (not a header, toolbar or panel laid over it) is what's on screen at `point`.
    private func isEditorShowing(at point: CGPoint, editor: AXUIElement) -> Bool {
        guard let appElement else { return false }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(appElement, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return true }   // the app can't say: don't hide anything
        return hit.isSame(as: editor) || hit.parent.map { $0.isSame(as: editor) } == true
    }

    /// The editor's position (which moves as it scrolls) and its visible area.
    private func currentLayout() -> (position: CGPoint, clip: CGRect)? {
        guard let editor, let frame = editor.frame else { return nil }
        var clip = scrollArea.flatMap(Accessibility.contentFrame(of:)) ?? frame
        if let window = editorWindow?.frame { clip = clip.intersection(window) }
        guard !clip.isNull, clip.width > 1, clip.height > 1 else { return nil }
        return (frame.origin, clip)
    }

    /// Highlights show only while the editor's window is the one being used.
    private func shouldShow() -> Bool {
        guard let appElement, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let hidden = appElement.value(kAXHiddenAttribute) as? Bool, hidden { return false }
        guard let window = appElement.element(kAXFocusedWindowAttribute), window.isSame(as: editorWindow) else { return false }
        return (editorWindow?.value(kAXMinimizedAttribute) as? Bool) != true
    }

    /// Catches scrolling, resizing and lost editors that the host app doesn't announce.
    private func poll() {
        guard let appElement else { return }
        pollTick += 1
        if ContinuousClock.now - lastActivity > .seconds(2), !pollTick.isMultiple(of: 5) { return }
        guard let editor else {
            locateEditor()
            return
        }
        // Another window of the same app came to the front without telling us.
        if let window = appElement.element(kAXFocusedWindowAttribute), !window.isSame(as: editorWindow) {
            locateEditor()
            return
        }
        guard let layout = currentLayout() else {
            if editor.frame == nil { locateEditor() } else { overlay.hide() }
            return
        }
        if lastLayout == nil || lastLayout!.position != layout.position || lastLayout!.clip != layout.clip {
            scheduleGeometry()
        } else if !overlay.isVisible, !tracked.isEmpty, shouldShow() {
            scheduleGeometry()   // e.g. back from a sheet or another window of the same app
        }
    }

    // MARK: Hover

    private func handleMouse(_ type: NSEvent.EventType) {
        lastActivity = .now
        let point = NSEvent.mouseLocation.flippedToAX
        switch type {
        case .scrollWheel:
            bubble.hide()
            scheduleGeometry()
        case .leftMouseDown:
            bubble.hide()   // clicks on the bubble itself are local events and don't arrive here
        default:
            guard let mark = overlay.mark(at: point) else {
                hoverTask?.cancel()
                if !bubble.keepsOpen(at: point) { bubble.hide() }
                return
            }
            guard bubble.markID != mark.id else { return }
            hoverTask?.cancel()
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self,
                      let current = self.overlay.mark(at: NSEvent.mouseLocation.flippedToAX), current.id == mark.id,
                      mark.id < self.tracked.count else { return }
                self.bubble.show(self.tracked[mark.id].tip, actions: self.actions(for: mark.id), for: mark.id,
                                 below: current.rect)
            }
        }
    }

    // MARK: Bubble actions

    private func actions(for id: Int) -> [HoverAction] {
        let item = tracked[id]
        var actions: [HoverAction] = []
        if item.group != nil {
            actions.append(HoverAction(title: "Show other", help: "Flash the nearest other use of this word") { [weak self] in
                self?.showOther(of: item)
            })
        }
        actions.append(HoverAction(title: "Ignore here", help: "Hide this one highlight") { [weak self] in
            self?.ignoreHere(item)
        })
        if item.isRepeat {
            actions.append(HoverAction(title: "Ignore in document",
                                       help: "Never flag “\(item.word)” in this \(self.appName) document") { [weak self] in
                self?.ignoreInDocument(item.forms)
            })
            actions.append(HoverAction(title: "Exclude everywhere",
                                       help: "Add “\(item.word)” to the exclude list, for every document") { [weak self] in
                item.forms.forEach { self?.onExclude?($0) }
            })
        }
        return actions
    }

    /// Flashes the nearest other occurrence; if it's off screen, selects it so the app scrolls to it.
    private func showOther(of item: Tracked) {
        let others = tracked.filter { $0.group == item.group && $0.range != item.range }.map(\.range)
        guard let editor, let target = others.min(by: {
            abs($0.location - item.range.location) < abs($1.location - item.range.location)
        }) else { return }
        if let rect = editor.bounds(for: target), let clip = lastLayout?.clip, clip.contains(CGPoint(x: rect.midX, y: rect.midY)) {
            overlay.flash(rect)
            return
        }
        var range = CFRange(location: target.location, length: target.length)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(editor, kAXSelectedTextRangeAttribute as CFString, value)
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))   // let the app scroll
            guard let self, let rect = self.editor?.bounds(for: target) else { return }
            self.updateGeometry()
            self.overlay.flash(rect)
        }
    }

    private func ignoreHere(_ item: Tracked) {
        ignoredHere.append(item.range)
        tracked.removeAll { $0.range == item.range }
        scheduleGeometry()
    }

    private func ignoreInDocument(_ words: [String]) {
        documentIgnores[documentKey, default: []] += words
        scheduleAnalysis(after: .zero)
    }
}

/// AXObserver delivers on the main run loop, where the source was added.
private let axCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else { return }
    let highlighter = Unmanaged<LiveHighlighter>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    nonisolated(unsafe) let element = element   // AXUIElement isn't marked Sendable; we're on the main thread
    MainActor.assumeIsolated { highlighter.handle(name, element: element) }
}
