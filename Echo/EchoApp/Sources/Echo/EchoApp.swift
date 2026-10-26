import AppKit
import SwiftUI

@main
struct EchoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Echo", systemImage: "text.magnifyingglass") {
            MenuContent()
                .environment(model)
        }

        Window("Check Text", id: WindowID.checkText) {
            CheckTextView()
                .environment(model)
        }
        .defaultSize(width: 1150, height: 780)

        Window("Echo Settings", id: WindowID.settings) {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let checkText = "check-text"
    static let settings = "settings"
}

private struct MenuContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Text(statusText)
        Toggle("Highlight in Writing Apps", isOn: $model.liveEnabled)
            .keyboardShortcut("e", modifiers: [.control, .option, .command])
        if model.pausedUntil != nil {
            Button("Resume Now") { model.resume() }
        } else if model.liveEnabled {
            Button("Pause for 1 Hour") { model.pause(for: .seconds(3600)) }
        }
        if model.live.status == .needsPermission {
            Button("Grant Accessibility Access…") {
                Accessibility.requestAccess()
                Accessibility.openSettings()
                model.live.recheckPermission()
            }
        }
        Divider()
        Button("Check Text…") {
            openWindow(id: WindowID.checkText)
            NSApp.activate()
        }
        .keyboardShortcut("k")
        if case .active(let app, _, _) = model.live.status {
            Button("Check This \(app) Document") {
                model.pendingCheckText = model.live.currentDocumentText()
                openWindow(id: WindowID.checkText)
                NSApp.activate()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        Button("Settings…") {
            openWindow(id: WindowID.settings)
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit Echo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        if let until = model.pausedUntil {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return switch model.live.status {
        case .off: "Highlighting is off"
        case .needsPermission: "Needs Accessibility access"
        case .idle: "Waiting for Scrivener or Vellum"
        case .noDocument(let app): "No document found in \(app)"
        case .active(let app, let repeats, let watch):
            "\(app): \(repeats) repeat\(repeats == 1 ? "" : "s"), \(watch) watch word\(watch == 1 ? "" : "s")"
        }
    }
}
