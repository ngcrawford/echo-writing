import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window (SPEC §5.5).
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            TuningPanel(includeLists: false)
                .tabItem { Label("Analysis", systemImage: "slider.horizontal.3") }
            Form { WordListSections() }
                .formStyle(.grouped)
                .tabItem { Label("Word Lists", systemImage: "list.bullet") }
            AppsTab()
                .tabItem { Label("Apps", systemImage: "app.badge.checkmark") }
        }
        .frame(width: 560, height: 620)
        .onAppear { model.windowOpened() }
        .onDisappear { model.windowClosed() }
    }
}

private struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var trusted = Accessibility.isTrusted

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Highlight in writing apps", isOn: $model.liveEnabled)
                LabeledContent("Turn on or off from anywhere", value: "⌃⌥⌘E")
                if let until = model.pausedUntil {
                    LabeledContent("Paused until \(until.formatted(date: .omitted, time: .shortened))") {
                        Button("Resume") { model.resume() }
                    }
                }
                Toggle("Open Echo at login", isOn: $model.launchAtLogin)
            }
            Section("Highlights") {
                Picker("Style", selection: $model.highlightStyle) {
                    Text("Underline").tag(HighlightStyle.underline)
                    Text("Background").tag(HighlightStyle.background)
                }
                LabeledContent("Repeats") { Text("Orange wavy underline").foregroundStyle(.orange) }
                LabeledContent("Watch-list words") { Text("Blue underline").foregroundStyle(.blue) }
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open System Settings…") {
                            Accessibility.requestAccess()
                            Accessibility.openSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            // Notice when access is granted while this window is open.
            while !Task.isCancelled {
                trusted = Accessibility.isTrusted
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct AppsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach($model.apps) { $app in
                    HStack {
                        Toggle(app.name, isOn: $app.enabled)
                        Spacer()
                        if !HostApp.defaults.contains(where: { $0.bundleID == app.bundleID }) {
                            Button("Remove", systemImage: "minus.circle") {
                                model.apps.removeAll { $0.bundleID == app.bundleID }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add App…", action: addApp)
            } header: {
                Text("Highlight in")
            } footer: {
                Text("Echo works best in apps with standard Mac text views. Scrivener and Vellum are tested; other apps may misplace highlights or not show them. Microsoft Word isn't supported yet — use Check Text instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !model.apps.contains(where: { $0.bundleID == id }) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        model.apps.append(HostApp(bundleID: id, name: name))
    }
}
