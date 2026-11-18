import Foundation

/// Priority flag attached to a task.
public enum TaskPriority: String, Codable, CaseIterable, Comparable, Sendable {
    case none, low, medium, high

    /// Position from least to most urgent.
    public var rank: Int {
        switch self {
        case .none: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rank < rhs.rank
    }

    public var label: String {
        switch self {
        case .none: "None"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

/// A node of the task tree. Every task can hold free-form notes and any number of subtasks,
/// which are themselves full tasks.
public struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var isDone: Bool
    public var priority: TaskPriority
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var children: [TaskItem]

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        isDone: Bool = false,
        priority: TaskPriority = .none,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        completedAt: Date? = nil,
        children: [TaskItem] = []
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.isDone = isDone
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
        self.children = children
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, isDone, priority, createdAt, updatedAt, completedAt, children
    }

    /// Lenient decoding: the data file is meant to be human-editable, so missing keys fall back
    /// to sensible defaults instead of failing the whole document.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        // An unknown value (from a newer version or a typo) degrades to "none".
        let rawPriority = try? container.decodeIfPresent(String.self, forKey: .priority)
        priority = rawPriority.flatMap(TaskPriority.init(rawValue:)) ?? .none
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        children = try container.decodeIfPresent([TaskItem].self, forKey: .children) ?? []
    }

    // MARK: Derived values

    /// Lower-cased `#tags` found in the title, in order of appearance and without duplicates.
    public var tags: [String] {
        var seen = Set<String>()
        return Self.tokens(of: title).compactMap { token in
            guard let tag = Self.tag(from: token), seen.insert(tag).inserted else { return nil }
            return tag
        }
    }

    /// The title with its `#tags` removed, for display next to tag chips.
    public var titleWithoutTags: String {
        let words = Self.tokens(of: title).filter { Self.tag(from: $0) == nil }
        let stripped = words.joined(separator: " ")
        return stripped.isEmpty ? title : stripped
    }

    public var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var doneChildCount: Int {
        children.reduce(0) { $0 + ($1.isDone ? 1 : 0) }
    }

    private static func tokens(of text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
    }

    private static func tag(from token: Substring) -> String? {
        guard token.hasPrefix("#") else { return nil }
        let body = token.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return body.isEmpty ? nil : body.lowercased()
    }
}

/// On-disk envelope for the task tree.
public struct TaskDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var tasks: [TaskItem]

    public init(schemaVersion: Int = TaskDocument.currentSchemaVersion, tasks: [TaskItem] = []) {
        self.schemaVersion = schemaVersion
        self.tasks = tasks
    }
}
