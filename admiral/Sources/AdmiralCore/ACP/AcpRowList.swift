import Foundation

/// A list as Settings → Agents edits it: one row per entry, each with a stable id so the view
/// can focus and reorder rows. There is always at least one row (an empty list shows one empty
/// row, its placeholder the shape). Used for argv lists (`AcpArgList`, one field per row) and
/// key/value maps (`AcpPairList`, two); what is saved is normalized by each.
public struct AcpRowList<Item: Equatable & Sendable>: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: UUID
        public var item: Item

        public init(id: UUID = UUID(), item: Item) {
            self.id = id
            self.item = item
        }
    }

    public private(set) var rows: [Row]
    private let blank: Item

    public init(_ items: [Item], blank: Item) {
        self.blank = blank
        rows = items.isEmpty ? [Row(item: blank)] : items.map { Row(item: $0) }
    }

    public subscript(id: UUID) -> Item {
        get { rows.first { $0.id == id }?.item ?? blank }
        set {
            guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[i].item = newValue
        }
    }

    /// Appends an empty row and returns its id (the view focuses it).
    @discardableResult
    public mutating func append() -> UUID {
        let row = Row(item: blank)
        rows.append(row)
        return row.id
    }

    /// Removes a row; removing the last one leaves a single empty row, never none.
    public mutating func remove(_ id: UUID) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { rows = [Row(item: blank)] }
    }

    /// Moves a row one place up (`by: -1`) or down (`by: 1`); a move past either end is a no-op.
    public mutating func move(_ id: UUID, by offset: Int) {
        guard canMove(id, by: offset), let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows.swapAt(i, i + offset)
    }

    /// Just the one empty row a fresh list shows — removing it would change nothing.
    public var isBlank: Bool { rows.count == 1 && rows[0].item == blank }

    public func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return false }
        return rows.indices.contains(i + offset)
    }
}

/// An argv list: one literal argument per row.
public typealias AcpArgList = AcpRowList<String>

public extension AcpRowList where Item == String {
    init(_ values: [String] = []) { self.init(values, blank: "") }

    /// The saved list: each row trimmed of surrounding whitespace, empty rows dropped, inner
    /// spaces kept (an arg with spaces stays one arg — no splitting).
    var values: [String] {
        rows.map { $0.item.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// One `KEY` / value row of an environment or config-options list.
public struct AcpPair: Equatable, Sendable {
    public var key: String
    public var value: String

    public init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

/// A key/value list (environment, config options). Rows with an empty key are dropped on save;
/// a key given twice is an error (`duplicateKeys`), never a silent last-wins.
public typealias AcpPairList = AcpRowList<AcpPair>

public extension AcpRowList where Item == AcpPair {
    /// Sorted by key, so a saved map always opens in the same order.
    init(_ map: [String: String] = [:]) {
        self.init(map.keys.sorted().map { AcpPair(key: $0, value: map[$0] ?? "") }, blank: AcpPair())
    }

    /// Rows with a key: the key trimmed, the value kept as typed.
    var pairs: [AcpPair] {
        rows.compactMap { row in
            let key = row.item.key.trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : AcpPair(key: key, value: row.item.value)
        }
    }

    /// The saved map. With a duplicate key the first row wins, but `duplicateKeys` refuses the save.
    var map: [String: String] {
        var out: [String: String] = [:]
        for pair in pairs where out[pair.key] == nil { out[pair.key] = pair.value }
        return out
    }

    /// Keys given on more than one row, in first-seen order.
    var duplicateKeys: [String] {
        var seen: Set<String> = []
        var dup: [String] = []
        for pair in pairs {
            if !seen.insert(pair.key).inserted, !dup.contains(pair.key) { dup.append(pair.key) }
        }
        return dup
    }
}
