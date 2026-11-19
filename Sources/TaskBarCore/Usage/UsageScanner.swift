import Darwin
import Dispatch
import Foundation

/// Keeps a running tally of Claude Code token usage across every transcript on disk.
///
/// Transcripts are streamed in chunks, never loaded whole. Each file remembers how far it was
/// read, so a refresh only reads bytes appended since the last one, and a file whose size and
/// modification date are unchanged is not opened at all. A message that Claude Code writes in
/// several streamed chunks is counted once, using its largest usage.
public actor UsageScanner {
    static let chunkSize = 4 << 20
    /// Bytes every usage line contains. Claude Code writes compact JSON, so the assistant type
    /// is matched exactly as written; lines without these bytes cannot produce a record.
    private static let usageMarker = Array(#""usage""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)

    private let projectsDirectory: URL
    private var files: [String: FileState] = [:]
    private var messages: [String: StoredMessage] = [:]

    private struct FileState: Sendable {
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

    /// A transcript that changed since the last refresh, as the actor saw it before reading.
    private struct Job: Sendable {
        let url: URL
        let path: String
        let projectFolder: String
        let size: Int
        let modifiedAt: Date
        let previous: FileState
    }

    /// What reading one job produced. It is applied back on the actor, in listing order.
    private struct Ingested: Sendable {
        var records: [UsageRecord] = []
        /// Byte offset just past the last complete line read.
        var offset = 0
        var bytesRead = 0
        /// The file shrank or was replaced, so what it contributed before is forgotten first.
        var restarted = false
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

        var jobs: [Job] = []
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
                let previous = files[path] ?? FileState()
                if files[path] != nil, previous.size == size, previous.modifiedAt == modifiedAt {
                    continue
                }
                jobs.append(Job(
                    url: url,
                    path: path,
                    projectFolder: project.lastPathComponent,
                    size: size,
                    modifiedAt: modifiedAt,
                    previous: previous
                ))
            }
        }

        // The transcripts are read in parallel, one file per iteration. This stays synchronous on
        // purpose: the actor never suspends mid-refresh, so no other call can interleave with it.
        // The results are applied below in listing order, as a sequential pass would.
        let jobList = jobs
        let slots = ResultSlots(count: jobList.count)
        DispatchQueue.concurrentPerform(iterations: jobList.count) { index in
            slots.values[index] = Self.read(jobList[index])
        }

        var bytesRead = 0
        for (index, job) in jobList.enumerated() {
            let result = slots.values[index]
            bytesRead += result.bytesRead
            apply(result, to: job)
        }

        for path in files.keys where !seen.contains(path) {
            if let state = files.removeValue(forKey: path) {
                forgetMessages(from: path, ids: state.messageIDs)
            }
        }
        return bytesRead
    }

    /// Stores what one read produced and records how far the file was read.
    private func apply(_ result: Ingested, to job: Job) {
        var state = job.previous
        if result.restarted {
            forgetMessages(from: job.path, ids: state.messageIDs)
            state = FileState()
        }
        for record in result.records {
            store(record, source: job.path, state: &state)
        }
        state.offset = result.offset
        state.size = job.size
        state.modifiedAt = job.modifiedAt
        files[job.path] = state
    }

    /// Reads the bytes appended to one transcript since the last refresh. Runs off the actor, so
    /// it touches no actor state.
    private static func read(_ job: Job) -> Ingested {
        var result = Ingested()
        var start = job.previous.offset
        if job.size < start {
            // Truncated or replaced: everything is read again from the beginning.
            result.restarted = true
            start = 0
        }
        result.offset = start
        guard job.size > start, let handle = try? FileHandle(forReadingFrom: job.url) else { return result }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(start))) != nil else { return result }

        // One buffer serves every chunk of this file: no allocation per chunk.
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }

        let parser = UsageLineParser()
        let sessionFallback = job.url.deletingPathExtension().lastPathComponent
        // Bytes after the last newline belong to a line still being written; they are carried
        // over and only processed once their newline arrives. Only that partial line is ever
        // copied: complete lines are examined in place inside the chunk.
        var carry: [UInt8] = []
        while true {
            let count = Darwin.read(handle.fileDescriptor, buffer.baseAddress, chunkSize)
            if count < 0, errno == EINTR { continue }
            // End of file, or an unreadable file: what was processed before it is kept.
            guard count > 0 else { break }
            result.bytesRead += count
            let chunk = UnsafeRawBufferPointer(rebasing: buffer[..<count])

            var from = 0
            if !carry.isEmpty {
                guard let newline = ByteSearch.firstNewline(in: chunk, from: 0) else {
                    carry.append(contentsOf: chunk)
                    continue
                }
                carry.append(contentsOf: chunk[..<newline])
                carry.withUnsafeBytes { line in
                    consume(line, projectFolder: job.projectFolder, sessionFallback: sessionFallback, parser: parser, into: &result.records)
                }
                // The carried line plus its newline, now processed.
                result.offset += carry.count + 1
                carry.removeAll(keepingCapacity: true)
                from = newline + 1
            }
            while let newline = ByteSearch.firstNewline(in: chunk, from: from) {
                let line = UnsafeRawBufferPointer(rebasing: chunk[from..<newline])
                consume(line, projectFolder: job.projectFolder, sessionFallback: sessionFallback, parser: parser, into: &result.records)
                result.offset += line.count + 1
                from = newline + 1
            }
            carry.append(contentsOf: chunk[from...])
        }
        return result
    }

    /// Examines one complete transcript line. Only lines that mention both `"usage"` and
    /// `"type":"assistant"` are copied and handed to the parser; the rest of the file is never
    /// decoded or copied.
    private static func consume(
        _ line: UnsafeRawBufferPointer,
        projectFolder: String,
        sessionFallback: String,
        parser: UsageLineParser,
        into records: inout [UsageRecord]
    ) {
        guard ByteSearch.contains(usageMarker, in: line),
              ByteSearch.contains(assistantMarker, in: line),
              let base = line.baseAddress
        else { return }
        guard let record = parser.record(
            from: Data(bytes: base, count: line.count),
            projectFolder: projectFolder,
            fallbackSessionID: sessionFallback
        ) else { return }
        records.append(record)
    }

    /// Preallocated results for `concurrentPerform`. Each iteration writes only its own index, so
    /// no two threads ever touch the same slot.
    private final class ResultSlots: @unchecked Sendable {
        let values: UnsafeMutableBufferPointer<Ingested>

        init(count: Int) {
            values = .allocate(capacity: count)
            values.initialize(repeating: Ingested())
        }

        deinit {
            values.deinitialize()
            values.deallocate()
        }
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
