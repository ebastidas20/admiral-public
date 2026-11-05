import Foundation

/// One value a select config option offers. `group` is the name of the group it came from
/// (a grouped select is flattened in order), nil for a flat list.
public struct AcpOptionValue: Hashable, Sendable, Codable {
    public var value: String
    public var name: String
    public var description: String?
    public var group: String?

    public init(value: String, name: String, description: String? = nil, group: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
        self.group = group
    }
}

/// A session config option the agent advertises (mode, model, effort, …) — or, for an agent
/// that sends only the deprecated `modes`, that object as one `mode` option. Which wire method
/// changes it is decided here, once (`setter`), never re-asked by a caller.
public struct AcpConfigOption: Hashable, Sendable, Codable, Identifiable {
    /// `configOption` → `session/set_config_option`; `legacyMode` → `session/set_mode`.
    public enum Setter: String, Hashable, Sendable, Codable { case configOption, legacyMode }

    public var id: String
    public var name: String
    public var description: String?
    /// A UX hint: "mode" | "model" | "model_config" | "thought_level" | "_…" | nil.
    public var category: String?
    public var currentValue: String?
    /// Grouped options flattened in order, `group` = the group's name.
    public var values: [AcpOptionValue]
    public var setter: Setter

    public init(
        id: String, name: String, description: String? = nil, category: String? = nil,
        currentValue: String?, values: [AcpOptionValue], setter: Setter = .configOption
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.currentValue = currentValue
        self.values = values
        self.setter = setter
    }

    /// The current value's display name, else the raw value.
    public var currentName: String? {
        currentValue.map { current in values.first { $0.value == current }?.name ?? current }
    }

    /// `configOptions` from a new/load/resume/set result (or a `config_option_update`); when no
    /// select option is kept (absent, empty, or only booleans), a `modes` object becomes ONE option `id:"mode"`, name "Mode", category
    /// "mode", setter `.legacyMode`. Only `type:"select"` options are kept — Admiral does not
    /// advertise boolean options.
    public static func decodeAll(_ result: JSONValue) -> [AcpConfigOption] {
        let kept = (result["configOptions"]?.arrayValue ?? []).compactMap(decodeSelect)
        guard kept.isEmpty else { return kept }
        return decodeModes(result["modes"]).map { [$0] } ?? []
    }

    private static func decodeSelect(_ o: JSONValue) -> AcpConfigOption? {
        guard let id = o["id"]?.stringValue, (o["type"]?.stringValue ?? "select") == "select" else { return nil }
        var values: [AcpOptionValue] = []
        for item in o["options"]?.arrayValue ?? [] {
            if let group = item["options"]?.arrayValue {
                let groupName = item["name"]?.stringValue ?? item["group"]?.stringValue
                values += group.compactMap { decodeValue($0, group: groupName) }
            } else if let value = decodeValue(item, group: nil) {
                values.append(value)
            }
        }
        return AcpConfigOption(
            id: id, name: o["name"]?.stringValue ?? id, description: o["description"]?.stringValue,
            category: o["category"]?.stringValue, currentValue: o["currentValue"]?.stringValue,
            values: values, setter: .configOption)
    }

    private static func decodeValue(_ v: JSONValue, group: String?) -> AcpOptionValue? {
        guard let value = v["value"]?.stringValue else { return nil }
        return AcpOptionValue(
            value: value, name: v["name"]?.stringValue ?? value,
            description: v["description"]?.stringValue, group: group)
    }

    private static func decodeModes(_ modes: JSONValue?) -> AcpConfigOption? {
        guard let modes, let available = modes["availableModes"]?.arrayValue, !available.isEmpty else { return nil }
        let values = available.compactMap { m -> AcpOptionValue? in
            guard let id = m["id"]?.stringValue else { return nil }
            return AcpOptionValue(value: id, name: m["name"]?.stringValue ?? id, description: m["description"]?.stringValue)
        }
        return AcpConfigOption(
            id: "mode", name: "Mode", category: "mode", currentValue: modes["currentModeId"]?.stringValue,
            values: values, setter: .legacyMode)
    }

    /// The picker's chip order: mode, model, model_config, thought_level, then others, each in agent order.
    public static func ordered(_ options: [AcpConfigOption]) -> [AcpConfigOption] {
        let rank = ["mode": 0, "model": 1, "model_config": 2, "thought_level": 3]
        return options.enumerated()
            .sorted { a, b in
                let (ra, rb) = (rank[a.element.category ?? ""] ?? 4, rank[b.element.category ?? ""] ?? 4)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }
}

extension [AcpConfigOption] {
    /// A `current_mode_update`: the `mode` option's current value becomes `id`.
    public func applyingCurrentMode(_ id: String) -> [AcpConfigOption] {
        map { option in
            guard option.id == "mode" else { return option }
            var o = option
            o.currentValue = id
            return o
        }
    }
}
