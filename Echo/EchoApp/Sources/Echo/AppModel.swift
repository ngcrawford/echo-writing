import AppKit
import Carbon.HIToolbox
import EchoEngine
import Observation
import ServiceManagement

enum HighlightStyle: String, Codable, CaseIterable {
    case underline, background
}

/// An app Echo can highlight in (SPEC §5.4).
struct HostApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var enabled = true
    var id: String { bundleID }

    static let defaults = [
        HostApp(bundleID: "com.literatureandlatte.scrivener3", name: "Scrivener"),
        HostApp(bundleID: "co.180g.Vellum", name: "Vellum"),
        HostApp(bundleID: "com.apple.TextEdit", name: "TextEdit"),
    ]
}

/// App-wide state: the analyzer and the user's settings, saved to UserDefaults.
@MainActor @Observable
final class AppModel {
    private(set) var analyzer: Analyzer?
    private(set) var loadError: String?

    /// Highlights inside Scrivener, Vellum and TextEdit.
    let live = LiveHighlighter()

    var settings: EngineSettings {
        didSet {
            save(settings, as: Keys.settings)
            live.settings = settings
        }
    }

    var highlightStyle: HighlightStyle {
        didSet {
            save(highlightStyle, as: Keys.highlightStyle)
            live.background = highlightStyle == .background
        }
    }

    var liveEnabled: Bool {
        didSet {
            save(liveEnabled, as: Keys.liveEnabled)
            if liveEnabled { pausedUntil = nil }
            updateLive()
        }
    }

    var apps: [HostApp] {
        didSet {
            save(apps, as: Keys.apps)
            updateLive()
        }
    }

    /// Text for the Check Text window to load when it next appears (from "Check This Document").
    var pendingCheckText: String?

    /// Set by "Pause for 1 Hour"; highlighting resumes by itself afterwards.
    private(set) var pausedUntil: Date?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: HotKey?

    /// Open windows that need the Dock icon and main menu (Check Text, Settings).
    @ObservationIgnored private var regularWindows = 0

    private enum Keys {
        static let settings = "engineSettings"
        static let highlightStyle = "highlightStyle"
        static let liveEnabled = "liveEnabled"
        static let apps = "apps"
    }

    init() {
        settings = Self.load(Keys.settings) ?? EngineSettings()
        highlightStyle = Self.load(Keys.highlightStyle) ?? .underline
        liveEnabled = Self.load(Keys.liveEnabled) ?? true
        apps = Self.load(Keys.apps) ?? HostApp.defaults
        live.settings = settings
        live.background = highlightStyle == .background
        live.onExclude = { [weak self] word in
            guard let self, !self.settings.excludeList.contains(word) else { return }
            self.settings.excludeList.append(word)
        }
        updateLive()
        hotKey = HotKey(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            self?.liveEnabled.toggle()
        }
        Task { await loadAnalyzer() }
    }

    private func updateLive() {
        live.apps = Dictionary(apps.filter(\.enabled).map { ($0.bundleID, $0.name) }, uniquingKeysWith: { a, _ in a })
        live.isEnabled = liveEnabled && pausedUntil == nil
    }

    // MARK: Pause

    func pause(for duration: Duration) {
        pausedUntil = Date().addingTimeInterval(TimeInterval(duration.components.seconds))
        updateLive()
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    func resume() {
        resumeTask?.cancel()
        pausedUntil = nil
        updateLive()
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    // MARK: Windows

    /// Agent apps have no menu bar or Dock icon; show them while a window is open so Edit › Paste, Undo,
    /// Find and ⌘W work normally.
    func windowOpened() {
        regularWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func windowClosed() {
        regularWindows = max(0, regularWindows - 1)
        if regularWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }

    private func loadAnalyzer() async {
        do {
            let table = try await Task.detached { try Self.loadTable() }.value
            analyzer = Analyzer(frequencies: table)
            live.analyzer = analyzer
        } catch {
            loadError = "Couldn't load the word-frequency table: \(error.localizedDescription)"
        }
    }

    /// The app bundle carries the table in Contents/Resources (see build.sh). `swift run` falls back to the
    /// engine package's own resource bundle.
    nonisolated private static func loadTable() throws -> FrequencyTable {
        if let url = Bundle.main.url(forResource: "zipf-en", withExtension: "tsv") {
            return try FrequencyTable(contentsOf: url)
        }
        return try FrequencyTable.bundled()
    }

    private func save<T: Encodable>(_ value: T, as key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
