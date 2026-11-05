import SwiftUI
import AdmiralCore

/// An ACP tab's config options in the composer's bottom bar: one menu chip per option (mode,
/// model, effort, …, in `AcpConfigOption.ordered` order), its label the current value. Picking
/// sets it on the agent; a refusal is handed to `onError` (nil = cleared, on every pick).
/// No options = no chips; a dead tab's chips are disabled.
struct AcpOptionChips: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let onError: (String?) -> Void

    var body: some View {
        let options = AcpConfigOption.ordered(session.acpConfigOptions)
        HStack(spacing: 4) {
            ForEach(options) { option in
                AcpOptionChip(option: option) { value in pick(option, value) }
                    .disabled(session.connectError != nil)
            }
        }
    }

    private func pick(_ option: AcpConfigOption, _ value: String) {
        onError(nil)
        let session = session
        Task {
            if let error = await model.setACPConfigOption(session, id: option.id, value: value) { onError(error) }
        }
    }
}

/// One option's chip: a borderless menu, items grouped by `group`, the current value checked.
struct AcpOptionChip: View {
    let option: AcpConfigOption
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(Self.groups(option.values), id: \.offset) { group in
                if let name = group.name {
                    Section(name) { items(group.values) }
                } else {
                    items(group.values)
                }
            }
        } label: {
            Text(option.chipLabel)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chipBackground))
        .help([option.name, option.description].compactMap { $0 }.joined(separator: " \u{2014} "))
        .accessibilityIdentifier("acp-option-\(option.id)")
    }

    @ViewBuilder private func items(_ values: [AcpOptionValue]) -> some View {
        ForEach(values, id: \.value) { value in
            Button { onPick(value.value) } label: {
                if value.value == option.currentValue {
                    Label(value.name, systemImage: "checkmark")
                } else {
                    Text(value.name)
                }
            }
            .help(value.description ?? "")
        }
    }

    /// Consecutive values sharing a group, in order (ungrouped values form one nameless run).
    static func groups(_ values: [AcpOptionValue]) -> [(offset: Int, name: String?, values: [AcpOptionValue])] {
        var out: [(offset: Int, name: String?, values: [AcpOptionValue])] = []
        for value in values {
            if let last = out.last, last.name == value.group {
                out[out.count - 1].values.append(value)
            } else {
                out.append((out.count, value.group, [value]))
            }
        }
        return out
    }
}

/// A refused pick, above the composer's text until the next pick.
struct AcpOptionErrorCaption: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("acp-option-error")
    }
}

/// The `/` menu above an ACP tab's composer: `/name` in mono, the description beside it.
/// Same look as the group `@` picker.
struct AcpSlashMenu: View {
    let candidates: [AcpCommandInfo]
    let selection: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates.indices, id: \.self) { i in row(i) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bubbleBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 8)
        .accessibilityIdentifier("acp-slash-menu")
    }

    private func row(_ i: Int) -> some View {
        let command = candidates[i]
        return HStack(spacing: 10) {
            Text("/\(command.name)")
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.primaryText)
            Text(command.description)
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText).lineLimit(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Theme.rowSelection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(i) }
        .accessibilityIdentifier("acp-slash-\(command.name)")
    }
}

/// What the `@` menu shows: a one-row notice while the list loads or when there is none to
/// load, else the matching files.
enum AcpFileMenuContent: Equatable {
    case notice(String)
    case files([String])

    static let loading = AcpFileMenuContent.notice("Loading files…")
    static let unavailable = AcpFileMenuContent.notice("File list unavailable: this agent has no exec command")
}

/// Where the composer's file list is for the open `@` query.
enum AcpFileListState: Equatable {
    case idle, loading, unavailable
    case loaded([String])
}

/// The `@` menu above an ACP tab's composer: each file's basename in bold, its path in mono
/// beside it. Same look as the `/` menu; a notice row is disabled.
struct AcpFileMenu: View {
    let content: AcpFileMenuContent
    let selection: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch content {
            case let .notice(text):
                Text(text)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("acp-file-notice")
            case let .files(files):
                ForEach(files.indices, id: \.self) { i in row(files[i], i) }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bubbleBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 8)
        .accessibilityIdentifier("acp-file-menu")
    }

    private func row(_ path: String, _ i: Int) -> some View {
        HStack(spacing: 10) {
            Text(FileMentionPicker.basename(path))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText).lineLimit(1)
            Text(path)
                .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Theme.rowSelection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(i) }
        .accessibilityIdentifier("acp-file-\(path)")
    }
}
