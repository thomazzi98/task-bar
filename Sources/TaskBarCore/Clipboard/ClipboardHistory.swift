import Foundation

/// One copied piece of text.
public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    /// When the text was last copied, not when it was first seen.
    public var copiedAt: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), text: String, copiedAt: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.copiedAt = copiedAt
        self.isPinned = isPinned
    }

    /// Short relative age for list rows: "just now", "2m ago", "3h ago", "4d ago".
    public func age(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(copiedAt)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }

    /// Whether the text reads like code, a path or a URL, so rows can show it in a monospaced font.
    public var looksLikeCode: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSingleToken = !trimmed.contains(where: \.isWhitespace)
        if isSingleToken, trimmed.contains("://") || trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            return true
        }
        if trimmed.filter({ "{}()[];=<>".contains($0) }).count >= 3 {
            return true
        }
        let lines = trimmed.split(whereSeparator: \.isNewline)
        return lines.count > 1 && lines.contains { $0.first?.isWhitespace == true }
    }
}

/// On-disk envelope for the clipboard history.
public struct ClipboardDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var items: [ClipboardItem]

    public init(schemaVersion: Int = ClipboardDocument.currentSchemaVersion, items: [ClipboardItem] = []) {
        self.schemaVersion = schemaVersion
        self.items = items
    }
}

/// The clipboard history: most recent copies first, with pinned items kept outside the limit.
public struct ClipboardHistory: Equatable, Sendable {
    /// Unpinned items kept at most. Pinned items are never evicted.
    public static let unpinnedLimit = 200

    /// Ordered by `copiedAt`, newest first.
    public private(set) var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = items
        sortByRecency()
        enforceLimit()
    }

    /// Pinned items first, then the rest; each group newest first.
    public var ordered: [ClipboardItem] {
        items.filter(\.isPinned) + items.filter { !$0.isPinned }
    }

    public var unpinnedCount: Int {
        items.lazy.filter { !$0.isPinned }.count
    }

    /// Records a copy. Text already in the history moves to the top with the new date instead
    /// of being stored twice. Returns the item's id, or `nil` when the text is not recordable.
    @discardableResult
    public mutating func insert(_ text: String, at date: Date = Date()) -> UUID? {
        guard let text = ClipboardPolicy.recordableText(text) else { return nil }
        if let index = items.firstIndex(where: { $0.text == text }) {
            items[index].copiedAt = date
            let id = items[index].id
            sortByRecency()
            return id
        }
        let item = ClipboardItem(text: text, copiedAt: date)
        items.append(item)
        sortByRecency()
        enforceLimit()
        return item.id
    }

    /// Pins or unpins an item. Unpinning can push the history over the limit, which evicts the
    /// oldest unpinned items as usual.
    public mutating func togglePin(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        enforceLimit()
    }

    public mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Removes every item that is not pinned.
    public mutating func clearUnpinned() {
        items.removeAll { !$0.isPinned }
    }

    /// Removes everything, pinned items included.
    public mutating func clearAll() {
        items.removeAll()
    }

    /// Items whose text contains every word of `query`, ignoring case and diacritics. An empty
    /// query returns everything. Results are in `ordered` order.
    public func search(_ query: String) -> [ClipboardItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return ordered }
        return ordered.filter { Search.matches($0.text, terms) }
    }

    // MARK: Private

    private mutating func sortByRecency() {
        // Ties keep their existing order, so the result is deterministic.
        items = items.enumerated().sorted { lhs, rhs in
            lhs.element.copiedAt != rhs.element.copiedAt
                ? lhs.element.copiedAt > rhs.element.copiedAt
                : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Drops the oldest unpinned items until the limit holds. Relies on `items` being sorted.
    private mutating func enforceLimit() {
        var excess = unpinnedCount - Self.unpinnedLimit
        var index = items.count - 1
        while excess > 0, index >= 0 {
            if !items[index].isPinned {
                items.remove(at: index)
                excess -= 1
            }
            index -= 1
        }
    }
}
