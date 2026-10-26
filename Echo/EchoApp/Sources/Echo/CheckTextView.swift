import AppKit
import EchoEngine
import SwiftUI
import UniformTypeIdentifiers

struct CheckTextView: View {
    @Environment(AppModel.self) private var model
    @State private var document = CheckTextDocument()
    @State private var sidebarTab = SidebarTab.report
    @State private var copiedReport = false

    enum SidebarTab: String, CaseIterable {
        case report = "Report"
        case tuning = "Tuning"
    }

    var body: some View {
        HSplitView {
            ZStack {
                DocumentTextView(document: document)
                if document.isEmpty {
                    placeholder
                }
            }
            .frame(minWidth: 480)

            VStack(spacing: 0) {
                Picker("", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
                switch sidebarTab {
                case .report: ReportPanel(document: document)
                case .tuning: TuningPanel(document: document)
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 480)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Paste", systemImage: "doc.on.clipboard", action: pasteReplacing)
                    .help("Replace the text with what's on the clipboard")
                Button("Open…", systemImage: "folder", action: openFile)
                    .help("Open a .txt, .rtf, .docx or .html file (e.g. a Scrivener export)")
                Button(copiedReport ? "Copied" : "Copy Report", systemImage: "list.clipboard", action: copyReport)
                    .disabled(document.result == nil || document.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.loadError {
                Text(error).padding(8).background(.red.opacity(0.85)).foregroundStyle(.white)
            }
        }
        .onAppear {
            model.windowOpened()
            document.settings = model.settings
            document.highlightStyle = model.highlightStyle
            document.analyzer = model.analyzer
        }
        .onDisappear { model.windowClosed() }
        .onChange(of: model.analyzer == nil) { document.analyzer = model.analyzer }
        .onChange(of: model.settings) { document.settings = model.settings }
        .onChange(of: model.highlightStyle) { document.highlightStyle = model.highlightStyle }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Paste a chapter, or open a file").font(.title3)
            Text("Repeats are underlined in orange, watch-list words in blue.\nHover over one to see why.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }

    private func pasteReplacing() {
        if let text = NSPasteboard.general.string(forType: .string) {
            document.replaceText(with: text)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .rtf, .rtfd, .html,
                                     UTType("org.openxmlformats.wordprocessingml.document") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.open(url: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func copyReport() {
        guard let report = document.result?.report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText(), forType: .string)
        copiedReport = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedReport = false
        }
    }
}

private struct DocumentTextView: NSViewRepresentable {
    let document: CheckTextDocument

    func makeNSView(context: Context) -> NSScrollView { document.scrollView }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
