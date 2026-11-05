import SwiftUI
import AppKit
import AdmiralCore

/// An ACP tab's log (`<base>/acp/<session>.log`), tailed: the JSON-RPC traffic both ways
/// (`acp: ->` / `acp: <-`), the agent's stderr, and Admiral's own notes on the tab. Re-read
/// every second while open (the last 256 KB), and kept scrolled to the end as it grows.
struct AcpLogView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: URL
    @State private var text = ""
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ACP log \u{00B7} \(title)").font(.system(size: 13, weight: .semibold))
                    Text((url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .disabled(!FileManager.default.fileExists(atPath: url.path))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    Text(text.isEmpty ? "Nothing logged yet." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(text.isEmpty ? Theme.secondaryText : Theme.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: text) { proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            .accessibilityIdentifier("acp-log-text")
        }
        .frame(width: 860, height: 560)
        .background(Theme.surface)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                SheetCloseButton(identifier: "acp-log-close") { dismiss() }
            }
        }
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
    }

    private func reload() {
        let url = self.url
        Task.detached(priority: .utility) {
            let tail = AcpLog.tail(url)
            await MainActor.run { if text != tail { text = tail } }
        }
    }
}
