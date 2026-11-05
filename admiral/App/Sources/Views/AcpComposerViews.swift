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
            Text(option.currentName ?? option.name)
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
