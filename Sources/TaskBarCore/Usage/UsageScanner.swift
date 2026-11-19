import Foundation

/// Keeps a running tally of Claude Code token usage across every transcript on disk.
///
/// Transcripts are streamed in chunks, never loaded whole. Each file remembers how far it was
/// read, so a refresh only reads bytes appended since the last one, and a file whose size and
/// modification date are unchanged is not opened at all. A message that Claude Code writes in
/// several streamed chunks is counted once, using its largest usage.
public actor UsageScanner {
    static let chunkSize = 1 << 20

    private let projectsDirectory: URL
    private let parser = UsageLineParser()
    private var files: [String: FileState] = [:]
    private var messages: [String: StoredMessage] = [:]

    private struct FileState {
        var size = 0
        var modifiedAt = Date.distantPast
        /// Byte offset just past the last complete line that was processed.
        var offset = 0
        var messageIDs: Set<String> = []
    }

    private struct StoredMessage {
        var record: UsageRecord
        /// The transcript file the kept copy came from.
        var source: String
    }

    public init(projectsDirectory: URL) {
        self.projectsDirectory = projectsDirectory
    }

    public init(paths: AppPaths) {
        self.init(projectsDirectory: paths.claudeProjectsDirectory)
    }

    /// Reads whatever changed on disk, then aggregates everything for the period.
    public func report(for period: UsagePeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageReport {
        let bytesRead = refresh()
        return UsageReport.make(
            records: messages.values.lazy.map(\.record),
            period: period,
            now: now,
            calendar: calendar,
            bytesRead: bytesRead
        )
    }

    // MARK: Private

    /// Brings every transcript up to date and returns how many bytes were read.
    private func refresh() -> Int {
        // Each project folder is listed directly, so its name comes from the folder itself and
        // no path arithmetic against the root is needed (the root and the enumerated paths can
        // differ by firmlinks such as /var and /private/var).
        let projects = (try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var bytesRead = 0
        var seen: Set<String> = []
        for project in projects {
            guard let enumerator = FileManager.default.enumerator(
                at: project,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let object = enumerator.nextObject() {
                guard let url = object as? URL, url.pathExtension == "jsonl" else { continue }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }

                let path = url.path
                seen.insert(path)
                let size = values?.fileSize ?? 0
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                if let state = files[path], state.size == size, state.modifiedAt == modifiedAt {
                    continue
                }
                bytesRead += ingest(url, path: path, projectFolder: project.lastPathComponent, size: size, modifiedAt: modifiedAt)
            }
        }

        for path in files.keys where !seen.contains(path) {
            if let state = files.removeValue(forKey: path) {
                forgetMessages(from: path, ids: state.messageIDs)
            }
        }
        return bytesRead
    }

    /// Reads the bytes appended to one transcript since the last refresh.
    private func ingest(_ url: URL, path: String, projectFolder: String, size: Int, modifiedAt: Date) -> Int {
        var state = files[path] ?? FileState()
        if size < state.offset {
            // The file was truncated or replaced: forget what it contributed and read it again.
            forgetMessages(from: path, ids: state.messageIDs)
            state = FileState()
        }

        var bytesRead = 0
        if size > state.offset, let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let sessionFallback = url.deletingPathExtension().lastPathComponent
            do {
                try handle.seek(toOffset: UInt64(state.offset))
                // Bytes after the last newline belong to a line still being written; they are
                // carried over and only processed once their newline arrives.
                var carry = Data()
                while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                    bytesRead += chunk.count
                    carry.append(chunk)
                    guard let newline = carry.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                    let complete = carry[..<(newline + 1)]
                    for line in complete.split(separator: UInt8(ascii: "\n")) {
                        guard let record = parser.record(
                            from: Data(line),
                            projectFolder: projectFolder,
                            fallbackSessionID: sessionFallback
                        ) else { continue }
                        store(record, source: path, state: &state)
                    }
                    state.offset += complete.count
                    carry = Data(carry[(newline + 1)...])
                }
            } catch {
                // An unreadable file keeps whatever was processed before the failure.
            }
        }

        state.size = size
        state.modifiedAt = modifiedAt
        files[path] = state
        return bytesRead
    }

    /// Keeps one copy per message id: the one with the most tokens, the latest on a tie.
    private func store(_ record: UsageRecord, source: String, state: inout FileState) {
        if let existing = messages[record.messageID], existing.record.usage.total > record.usage.total {
            return
        }
        messages[record.messageID] = StoredMessage(record: record, source: source)
        state.messageIDs.insert(record.messageID)
    }

    private func forgetMessages(from path: String, ids: Set<String>) {
        for id in ids where messages[id]?.source == path {
            messages[id] = nil
        }
    }
}
