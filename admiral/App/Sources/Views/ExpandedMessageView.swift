import SwiftUI
import AdmiralCore

/// One agent message, full size, in a resizable window of its own: rendered as the Chat
/// renders it (`ChatMarkdownView`), with Copy.
struct ExpandedMessage: Codable, Hashable {
    static let windowID = "expanded-message"
    var text: String
    var cwd: String
    var title: String
}

struct ExpandedMessageView: View {
    @EnvironmentObject var model: AppModel
    let message: ExpandedMessage
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(message.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer()
                CopyControl(label: "Copy message", copied: $copied) { ChatClipboard.copy(message.text) }
                    .accessibilityIdentifier("expanded-copy")
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            Divider().opacity(0.5)
            ScrollView {
                ChatMarkdownView(text: message.text, cwd: message.cwd, fontSize: 14.5)
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(Theme.contentBackground)
        .environment(\.openURL, model.chatOpenURL)
        .preferredColorScheme(model.preferredColorScheme)
        .navigationTitle(message.title)
    }
}
