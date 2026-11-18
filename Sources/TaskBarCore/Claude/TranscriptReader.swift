import Foundation

/// Reads only the end of a transcript file.
///
/// Session logs grow to tens of megabytes, while the app only ever needs the most recent
/// exchanges, so the file is never loaded whole.
public enum TranscriptTailReader {
    public static let defaultWindow = 256 * 1024
    public static let maximumWindow = 4 * 1024 * 1024

    /// Complete lines found in the last `maxBytes` of the file, oldest first.
    public static func readTailLines(of url: URL, maxBytes: Int = defaultWindow) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let offset = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // When the window starts mid-file its first line is almost certainly cut in half.
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        return lines.map { Data($0) }
    }

    /// Summarizes the recent conversation, widening the window when a single huge record
    /// crowds the conversation out of the default one.
    public static func summarize(_ url: URL) throws -> TranscriptSummary {
        let fileSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        var window = defaultWindow
        while true {
            let summary = TranscriptParser.summarize(lines: try readTailLines(of: url, maxBytes: window))
            let readWholeFile = window >= fileSize
            if summary.entries.count >= 6 || readWholeFile || window >= maximumWindow {
                return summary
            }
            window *= 4
        }
    }
}

/// Finds the transcript file that belongs to a session.
public struct TranscriptLocator: Sendable {
    public let projectsDirectory: URL

    public init(projectsDirectory: URL) {
        self.projectsDirectory = projectsDirectory
    }

    /// Claude Code stores a project's transcripts in a folder named after its working
    /// directory with every non-alphanumeric character replaced by a dash.
    public static func encodedProjectName(for cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let isAlphanumeric = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
            return isAlphanumeric ? Character(scalar) : "-"
        })
    }

    public func transcriptURL(sessionID: String, cwd: String) -> URL? {
        let fileName = "\(sessionID).jsonl"
        let fileManager = FileManager.default

        let expected = projectsDirectory
            .appendingPathComponent(Self.encodedProjectName(for: cwd))
            .appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: expected.path) { return expected }

        // A session keeps its original project folder even after `cd`-ing elsewhere, so fall
        // back to looking for the session ID across all project folders.
        let projects = (try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return projects
            .map { $0.appendingPathComponent(fileName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }
}
