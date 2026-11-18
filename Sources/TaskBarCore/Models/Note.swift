import Foundation

/// What a note is for. The kind decides how "Tidy up" rewrites it.
public enum NoteKind: String, Codable, CaseIterable, Sendable {
    /// A plain annotation: ideas, references, meeting scribbles.
    case note
    /// A draft prompt meant to be pasted into an AI tool.
    case prompt

    public var label: String {
        switch self {
        case .note: "Note"
        case .prompt: "Prompt"
        }
    }
}

/// A free-standing note. Notes are deliberately separate from tasks: they have no checkbox,
/// no hierarchy, and are meant for ideas, references, meeting scribbles and prompt drafts.
public struct Note: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    public var kind: NoteKind
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        kind: NoteKind = .note,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, kind, isPinned, createdAt, updatedAt
    }

    /// Lenient decoding, so a hand-edited file with missing or unknown values still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        let rawKind = try container.decodeIfPresent(String.self, forKey: .kind)
        kind = rawKind.flatMap(NoteKind.init(rawValue:)) ?? .note
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    /// Title to show in lists: the explicit title, or the first non-empty line of the body.
    public var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        guard let firstLine = readableLines.first else {
            return kind == .prompt ? "Untitled prompt" : "Untitled note"
        }
        return String(firstLine.prefix(80))
    }

    /// One-line preview of the body for list rows, with Markdown markers removed.
    public var preview: String {
        let titleIsFirstLine = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let rest = titleIsFirstLine ? Array(readableLines.dropFirst()) : readableLines
        return String(rest.joined(separator: " · ").prefix(140))
    }

    /// The body's non-empty lines as plain text.
    private var readableLines: [String] {
        body.split(whereSeparator: \.isNewline)
            .map { MarkdownBlockParser.plainText(ofLine: String($0)) }
            .filter { !$0.isEmpty }
    }

    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// On-disk envelope for the notes list.
public struct NotesDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var notes: [Note]

    public init(schemaVersion: Int = NotesDocument.currentSchemaVersion, notes: [Note] = []) {
        self.schemaVersion = schemaVersion
        self.notes = notes
    }
}
