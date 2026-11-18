import Foundation

/// Builds the list of live agent sessions from the session registry, the hook spool and the
/// transcript tails. All file access happens on this actor, off the main thread.
public actor AgentScanner {
    private let registry: SessionRegistry
    private let locator: TranscriptLocator
    private let spool: HookEventSpool
    private let isAlive: @Sendable (Int32) -> Bool

    private var hookPhases: [String: HookPhase] = [:]
    private var hookTranscriptPaths: [String: URL] = [:]
    private var acknowledgedAt: [String: Date] = [:]
    /// When each session was first observed. Turns that ended earlier were never "new" to
    /// the user, so they must not be highlighted as freshly finished.
    private var firstSeenAt: [String: Date] = [:]
    private var transcriptCache: [String: CachedTranscript] = [:]

    private struct CachedTranscript {
        var url: URL
        var modifiedAt: Date
        var size: Int
        var summary: TranscriptSummary
    }

    public init(
        paths: AppPaths,
        isAlive: @escaping @Sendable (Int32) -> Bool = { ProcessInspector.isAlive($0) }
    ) {
        self.registry = SessionRegistry(directory: paths.claudeSessionsDirectory)
        self.locator = TranscriptLocator(projectsDirectory: paths.claudeProjectsDirectory)
        self.spool = HookEventSpool(directory: paths.hookEventsDirectory)
        self.isAlive = isAlive
    }

    /// Reads pending hook events and folds them into the per-session state.
    @discardableResult
    public func ingestHookEvents(now: Date = Date()) -> [HookEvent] {
        let events = spool.drain(now: now)
        for event in events {
            apply(event)
        }
        return events
    }

    /// Applies one hook event. Exposed separately so tests can feed events directly.
    public func apply(_ event: HookEvent) {
        if let path = event.transcriptPath {
            hookTranscriptPaths[event.sessionID] = URL(fileURLWithPath: path)
        }
        switch event.kind {
        case .sessionEnd:
            forget(event.sessionID)
        case .sessionStart:
            hookPhases[event.sessionID] = nil
        default:
            hookPhases[event.sessionID] = HookPhaseReducer.reduce(hookPhases[event.sessionID], with: event)
        }
    }

    /// Marks finished turns as seen, so they stop being highlighted.
    public func acknowledge(sessionIDs: [String], at date: Date = Date()) {
        for sessionID in sessionIDs {
            acknowledgedAt[sessionID] = date
        }
    }

    public func scan(now: Date = Date()) -> [AgentSession] {
        let records = registry.records(isAlive: isAlive).filter(\.isInteractive)
        let liveIDs = Set(records.map(\.sessionID))
        for sessionID in Set(hookPhases.keys).union(transcriptCache.keys).union(firstSeenAt.keys).subtracting(liveIDs) {
            forget(sessionID)
        }

        return records
            .map { session(for: $0, now: now) }
            .sorted { lhs, rhs in
                if lhs.status.sortRank != rhs.status.sortRank {
                    return lhs.status.sortRank < rhs.status.sortRank
                }
                return (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
            }
    }

    // MARK: Private

    private func session(for record: SessionRecord, now: Date) -> AgentSession {
        let transcriptURL = hookTranscriptPaths[record.sessionID]
            ?? transcriptCache[record.sessionID]?.url
            ?? locator.transcriptURL(sessionID: record.sessionID, cwd: record.cwd)
        let summary = transcriptURL.map { loadSummary(for: record.sessionID, at: $0) } ?? TranscriptSummary.empty

        let firstSeen = firstSeenAt[record.sessionID] ?? now
        firstSeenAt[record.sessionID] = firstSeen
        let seenUntil = max(acknowledgedAt[record.sessionID] ?? firstSeen, firstSeen)

        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: record.status,
            waitingFor: record.waitingFor,
            registryUpdatedAt: record.updatedAt,
            statusUpdatedAt: record.statusUpdatedAt,
            hookPhase: hookPhases[record.sessionID],
            pendingTools: summary.pendingTools,
            lastStopReason: summary.lastStopReason,
            lastActivity: summary.lastActivity,
            hasConversation: summary.hasConversation,
            acknowledgedAt: seenUntil,
            now: now
        ))

        return AgentSession(
            id: record.sessionID,
            pid: record.pid,
            cwd: record.cwd,
            registryName: record.name,
            entrypoint: record.entrypoint,
            title: summary.title,
            status: resolved.status,
            statusDetail: resolved.detail,
            lastPrompt: summary.lastPrompt,
            lastAssistantText: summary.lastAssistantText,
            gitBranch: summary.gitBranch,
            model: summary.model,
            startedAt: record.startedAt,
            lastActivity: summary.lastActivity ?? record.statusUpdatedAt,
            entries: summary.entries,
            transcriptURL: transcriptURL
        )
    }

    /// Re-reads a transcript only when the file changed since the last scan.
    private func loadSummary(for sessionID: String, at url: URL) -> TranscriptSummary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modifiedAt = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = attributes?[.size] as? Int ?? 0

        if let cached = transcriptCache[sessionID],
           cached.url == url, cached.modifiedAt == modifiedAt, cached.size == size {
            return cached.summary
        }

        let summary = (try? TranscriptTailReader.summarize(url)) ?? .empty
        transcriptCache[sessionID] = CachedTranscript(url: url, modifiedAt: modifiedAt, size: size, summary: summary)
        return summary
    }

    private func forget(_ sessionID: String) {
        hookPhases[sessionID] = nil
        hookTranscriptPaths[sessionID] = nil
        acknowledgedAt[sessionID] = nil
        firstSeenAt[sessionID] = nil
        transcriptCache[sessionID] = nil
    }
}
