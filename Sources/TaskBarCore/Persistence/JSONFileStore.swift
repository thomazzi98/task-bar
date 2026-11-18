import Foundation

/// Result of loading a document while tolerating a missing or damaged file.
public struct LoadOutcome<Document: Sendable>: Sendable {
    public var document: Document
    /// Where an unreadable file was moved to, when recovery kicked in.
    public var quarantinedFile: URL?
    /// Human-readable description of the load failure, if any.
    public var failureDescription: String?
}

/// Reads and writes one `Codable` document as pretty-printed JSON.
///
/// Writes are atomic (temp file + rename), so a crash mid-save never leaves a half-written
/// file. A file that cannot be decoded is moved aside rather than overwritten, so user data
/// is never silently destroyed.
public struct JSONFileStore<Document: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Returns the stored document, or `nil` when the file does not exist yet.
    public func load() throws -> Document? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.makeDecoder().decode(Document.self, from: data)
    }

    public func save(_ document: Document) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.makeEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }

    /// Loads the document, falling back to `fallback` when the file is missing. An unreadable
    /// file is renamed to `<name>.corrupt-<timestamp>.json` so it can be inspected or restored.
    public func loadOrRecover(default fallback: @autoclosure () -> Document) -> LoadOutcome<Document> {
        do {
            return LoadOutcome(document: try load() ?? fallback(), quarantinedFile: nil, failureDescription: nil)
        } catch {
            let quarantined = try? quarantine()
            return LoadOutcome(
                document: fallback(),
                quarantinedFile: quarantined,
                failureDescription: error.localizedDescription
            )
        }
    }

    private func quarantine() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let name = url.deletingPathExtension().lastPathComponent
        let destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(stamp).json")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
