import Foundation

/// One saved link. The URL is stored as the normalized absolute string.
public struct LinkItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, url: String, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.createdAt = createdAt
    }

    /// The stored link as a URL, or `nil` if the stored text no longer parses.
    public var destination: URL? {
        URL(string: url)
    }
}

/// A named group of links, shown as one tile on the Links home screen.
public struct LinkFolder: Identifiable, Codable, Equatable, Sendable {
    /// Colours a folder can take. The UI maps each name to a palette colour.
    public static let colorNames = ["blue", "green", "orange", "red", "purple", "pink", "teal", "gray"]
    /// Icons a folder can take, all SF Symbols.
    public static let symbolNames = [
        "folder", "star", "briefcase", "book", "hammer",
        "globe", "play.rectangle", "cart", "graduationcap", "person.2",
    ]

    public var id: UUID
    public var name: String
    public var colorName: String
    public var symbol: String
    public var links: [LinkItem]

    public init(
        id: UUID = UUID(),
        name: String,
        colorName: String = "blue",
        symbol: String = "folder",
        links: [LinkItem] = []
    ) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.symbol = symbol
        self.links = links
    }
}

/// On-disk envelope for the links file.
public struct LinksDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var folders: [LinkFolder]

    public init(schemaVersion: Int = LinksDocument.currentSchemaVersion, folders: [LinkFolder] = []) {
        self.schemaVersion = schemaVersion
        self.folders = folders
    }
}
