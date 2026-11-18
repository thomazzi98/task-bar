import Foundation
import Testing
@testable import TaskBarCore

@Suite("Session registry")
struct SessionRegistryTests {
    private let recordJSON = """
    {
      "pid": 4242,
      "sessionId": "35d4a2c9-0892",
      "cwd": "/Users/dev/projects/task-bar",
      "startedAt": 1795010010602,
      "name": "task-bar-47",
      "kind": "interactive",
      "entrypoint": "claude-vscode",
      "status": "busy",
      "waitingFor": "dialog open",
      "updatedAt": 1795010336152,
      "statusUpdatedAt": 1795010336000
    }
    """

    @Test func parsesARegistryRecord() throws {
        let record = try #require(SessionRecord(json: Data(recordJSON.utf8)))
        #expect(record.pid == 4242)
        #expect(record.sessionID == "35d4a2c9-0892")
        #expect(record.cwd == "/Users/dev/projects/task-bar")
        #expect(record.name == "task-bar-47")
        #expect(record.status == "busy")
        #expect(record.waitingFor == "dialog open")
        #expect(record.entrypoint == "claude-vscode")
        #expect(record.isInteractive)
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_795_010_010.602))
        #expect(record.updatedAt == Date(timeIntervalSince1970: 1_795_010_336.152))
    }

    @Test func requiresOnlyTheEssentialFields() throws {
        let minimal = try #require(SessionRecord(json: Data(#"{"pid":7,"sessionId":"s","cwd":"/tmp"}"#.utf8)))
        #expect(minimal.status == nil)
        #expect(minimal.waitingFor == nil)
        #expect(minimal.isInteractive)

        #expect(SessionRecord(json: Data(#"{"pid":7,"cwd":"/tmp"}"#.utf8)) == nil)
        #expect(SessionRecord(json: Data(#"{"sessionId":"s","cwd":"/tmp"}"#.utf8)) == nil)
        #expect(SessionRecord(json: Data("garbage".utf8)) == nil)
    }

    @Test func treatsHeadlessRunsAsNonInteractive() throws {
        let record = try #require(SessionRecord(json: Data(#"{"pid":7,"sessionId":"s","cwd":"/tmp","kind":"print"}"#.utf8)))
        #expect(!record.isInteractive)
    }

    @Test func listsOnlyLiveSessions() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let directory = temp.paths.claudeSessionsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(#"{"pid":100,"sessionId":"alive","cwd":"/a"}"#.utf8).write(to: directory.appendingPathComponent("100.json"))
        try Data(#"{"pid":200,"sessionId":"dead","cwd":"/b"}"#.utf8).write(to: directory.appendingPathComponent("200.json"))
        try Data("{ broken".utf8).write(to: directory.appendingPathComponent("300.json"))
        try Data("secret".utf8).write(to: directory.appendingPathComponent("100.abcdef.key"))

        let records = SessionRegistry(directory: directory).records(isAlive: { $0 == 100 })
        #expect(records.map(\.sessionID) == ["alive"])
    }

    @Test func missingDirectoryMeansNoSessions() {
        let registry = SessionRegistry(directory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(registry.records(isAlive: { _ in true }).isEmpty)
    }
}

@Suite("Agent status resolver")
struct AgentStatusResolverTests {
    private let now = referenceDate
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private let bashTool = PendingTool(id: "t1", name: "Bash", summary: "Run the test suite")
    private let question = PendingTool(id: "q1", name: "AskUserQuestion", summary: "Redis or in-memory?")

    @Test func busyRegistryMeansWorking() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            pendingTools: [bashTool],
            hasConversation: true,
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .working, detail: "Bash: Run the test suite"))
    }

    @Test func registryWaitingOnADialogNeedsApproval() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            waitingFor: "dialog open",
            pendingTools: [bashTool],
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsApproval, detail: "Bash: Run the test suite"))
    }

    @Test func registryWaitingOnInputNeedsAnAnswer() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            waitingFor: "input needed",
            now: now
        ))
        #expect(resolved.status == .needsAnswer)
    }

    @Test func aPendingQuestionWinsOverAGenericDialog() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            waitingFor: "dialog open",
            pendingTools: [question],
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsAnswer, detail: "Redis or in-memory?"))
    }

    @Test func hookDetailIsUsedWhenTheRegistryIsWaiting() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            waitingFor: "dialog open",
            hookPhase: .awaitingApproval(detail: "Bash: rm -rf build", since: ago(2)),
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsApproval, detail: "Bash: rm -rf build"))
    }

    @Test func permissionHookNeedsApprovalEvenWithoutRegistrySupport() {
        // Older Claude Code versions never set `waitingFor`; the hook alone must be enough.
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            registryUpdatedAt: ago(30),
            hookPhase: .awaitingApproval(detail: "Edit: App.swift", since: ago(3)),
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsApproval, detail: "Edit: App.swift"))
    }

    @Test func approvalClearsOnceTheRegistryMovesOn() {
        // The dialog was answered: the registry changed after the hook and reports no wait.
        // The approved command may run for minutes before `PostToolUse` arrives.
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            registryUpdatedAt: ago(1),
            hookPhase: .awaitingApproval(detail: "Bash: make release", since: ago(10)),
            pendingTools: [bashTool],
            now: now
        ))
        #expect(resolved.status == .working)
    }

    @Test func registryUpdateWithinTheLagWindowDoesNotClearApproval() {
        let since = ago(5)
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            registryUpdatedAt: since.addingTimeInterval(0.2),
            hookPhase: .awaitingApproval(detail: nil, since: since),
            pendingTools: [bashTool],
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsApproval, detail: "Bash: Run the test suite"))
    }

    @Test func inputHookNeedsAnAnswer() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            hookPhase: .awaitingInput(detail: "Which environment?", since: ago(1)),
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsAnswer, detail: "Which environment?"))
    }

    @Test func unansweredQuestionInTranscriptNeedsAnAnswerWithoutAnyOtherSignal() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "busy",
            pendingTools: [question],
            hasConversation: true,
            now: now
        ))
        #expect(resolved == ResolvedAgentStatus(status: .needsAnswer, detail: "Redis or in-memory?"))
    }

    @Test func idleWithAnUnseenTurnIsFinished() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "idle",
            lastStopReason: "end_turn",
            lastActivity: ago(60),
            hasConversation: true,
            now: now
        ))
        #expect(resolved.status == .finished)
    }

    @Test func acknowledgingAFinishedTurnMakesItIdle() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "idle",
            lastActivity: ago(60),
            hasConversation: true,
            acknowledgedAt: ago(10),
            now: now
        ))
        #expect(resolved.status == .idle)
    }

    @Test func aNewTurnAfterAcknowledgementIsFinishedAgain() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(
            registryStatus: "idle",
            hookPhase: .stopped(since: ago(5)),
            lastActivity: ago(6),
            hasConversation: true,
            acknowledgedAt: ago(100),
            now: now
        ))
        #expect(resolved.status == .finished)
    }

    @Test func aFreshSessionWithoutConversationIsIdle() {
        let resolved = AgentStatusResolver.resolve(AgentStatusInput(registryStatus: "idle", now: now))
        #expect(resolved.status == .idle)
    }

    @Test func infersActivityWhenTheRegistryHasNoStatus() {
        // Hooks say it is working.
        #expect(AgentStatusResolver.resolve(AgentStatusInput(
            hookPhase: .working(since: ago(120)), hasConversation: true, now: now
        )).status == .working)

        // Hooks say it stopped.
        #expect(AgentStatusResolver.resolve(AgentStatusInput(
            hookPhase: .stopped(since: ago(5)), hasConversation: true, now: now
        )).status == .finished)

        // No hooks: recent transcript writes mean it is still going...
        #expect(AgentStatusResolver.resolve(AgentStatusInput(
            lastStopReason: "tool_use", lastActivity: ago(3), hasConversation: true, now: now
        )).status == .working)

        // ...unless the last message ended the turn, or the transcript has gone quiet.
        #expect(AgentStatusResolver.resolve(AgentStatusInput(
            lastStopReason: "end_turn", lastActivity: ago(3), hasConversation: true, now: now
        )).status == .finished)
        #expect(AgentStatusResolver.resolve(AgentStatusInput(
            lastStopReason: "tool_use", lastActivity: ago(300), hasConversation: true, acknowledgedAt: ago(1), now: now
        )).status == .idle)
    }

    @Test func attentionAndSortingHelpers() {
        #expect(AgentStatus.needsApproval.needsAttention)
        #expect(AgentStatus.needsAnswer.needsAttention)
        #expect(!AgentStatus.working.needsAttention)
        #expect(!AgentStatus.finished.needsAttention)
        let ordered = AgentStatus.allCases.sorted { $0.sortRank < $1.sortRank }
        #expect(ordered == [.needsApproval, .needsAnswer, .working, .finished, .idle])
    }
}

@Suite("Agent scanner")
struct AgentScannerTests {
    /// Earlier than every timestamp used by the transcript fixtures.
    private let beforeTheConversation = referenceDate.addingTimeInterval(-100_000)

    private func writeSession(
        in temp: TemporaryDirectory,
        pid: Int32 = 501,
        sessionID: String = "session-1",
        cwd: String = "/work/app",
        status: String = "busy",
        kind: String = "interactive",
        updatedAtMilliseconds: Int = 1_794_999_000_000,
        transcript: [Data]
    ) throws {
        let paths = temp.paths
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.claudeSessionsDirectory, withIntermediateDirectories: true)
        let record: [String: Any] = [
            "pid": pid, "sessionId": sessionID, "cwd": cwd, "status": status, "kind": kind,
            "name": "app-01", "entrypoint": "cli", "updatedAt": updatedAtMilliseconds
        ]
        try JSONSerialization.data(withJSONObject: record)
            .write(to: paths.claudeSessionsDirectory.appendingPathComponent("\(pid).json"))

        let transcriptURL = paths.claudeProjectsDirectory
            .appendingPathComponent(TranscriptLocator.encodedProjectName(for: cwd))
            .appendingPathComponent("\(sessionID).jsonl")
        try fileManager.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data.jsonLines(transcript).write(to: transcriptURL)
    }

    @Test func buildsASessionFromRegistryAndTranscript() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, transcript: [
            TranscriptFixture.raw(#"{"type":"ai-title","aiTitle":"Add caching layer"}"#),
            try TranscriptFixture.userPrompt("add a cache to the API client"),
            try TranscriptFixture.toolUse(id: "t1", name: "Bash", input: ["command": "swift build"])
        ])

        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })
        let sessions = await scanner.scan(now: referenceDate)

        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.id == "session-1")
        #expect(session.pid == 501)
        #expect(session.projectName == "app")
        #expect(session.title == "Add caching layer")
        #expect(session.displayTitle == "Add caching layer")
        #expect(session.lastPrompt == "add a cache to the API client")
        #expect(session.status == .working)
        #expect(session.statusDetail == "Bash: swift build")
        #expect(session.entries.count == 2)
        #expect(session.resumeCommand == "cd '/work/app' && claude --resume session-1")
    }

    @Test func permissionHookFlipsTheSessionToNeedsApproval() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, transcript: [try TranscriptFixture.userPrompt("deploy")])
        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })

        await scanner.apply(HookEvent(
            kind: .permissionRequested,
            sessionID: "session-1",
            detail: "Bash: ./deploy.sh production",
            receivedAt: referenceDate
        ))
        var sessions = await scanner.scan(now: referenceDate)
        var session = try #require(sessions.first)
        #expect(session.status == .needsApproval)
        #expect(session.statusDetail == "Bash: ./deploy.sh production")

        // The tool ran, so the dialog is gone.
        await scanner.apply(HookEvent(kind: .toolFinished, sessionID: "session-1", receivedAt: referenceDate))
        sessions = await scanner.scan(now: referenceDate)
        session = try #require(sessions.first)
        #expect(session.status == .working)
    }

    @Test func readsHookEventsFromTheSpool() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, status: "idle", transcript: [
            try TranscriptFixture.userPrompt("summarize the repo"),
            try TranscriptFixture.assistantText("Here is the summary.")
        ])
        let spool = HookEventSpool(directory: temp.paths.hookEventsDirectory)
        try spool.open(processID: 1)
        try Data(#"{"hook_event_name":"Notification","session_id":"session-1","notification_type":"agent_needs_input","message":"Pick a region"}"#.utf8)
            .write(to: temp.paths.hookEventsDirectory.appendingPathComponent("1-1.json"))

        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })
        let events = await scanner.ingestHookEvents(now: referenceDate)
        #expect(events.count == 1)

        let sessions = await scanner.scan(now: referenceDate)
        let session = try #require(sessions.first)
        #expect(session.status == .needsAnswer)
        #expect(session.statusDetail == "Pick a region")
    }

    @Test func acknowledgingClearsTheFinishedHighlight() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, status: "idle", transcript: [
            try TranscriptFixture.userPrompt("rename the module"),
            try TranscriptFixture.assistantText("Done.")
        ])
        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })

        // The app was already watching when the turn ended, so it counts as unseen.
        let before = await scanner.scan(now: beforeTheConversation)
        #expect(before.first?.status == .finished)
        await scanner.acknowledge(sessionIDs: ["session-1"], at: referenceDate)
        let after = await scanner.scan(now: referenceDate)
        #expect(after.first?.status == .idle)
    }

    @Test func turnsThatEndedBeforeTheAppSawTheSessionAreNotHighlighted() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, status: "idle", transcript: [
            try TranscriptFixture.userPrompt("rename the module"),
            try TranscriptFixture.assistantText("Done.")
        ])
        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })

        // First sight happens long after the conversation ended (e.g. the app just launched).
        let sessions = await scanner.scan(now: referenceDate)
        #expect(sessions.first?.status == .idle)
    }

    @Test func hidesHeadlessAndDeadSessions() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, pid: 1, sessionID: "interactive", transcript: [])
        try writeSession(in: temp, pid: 2, sessionID: "headless", kind: "print", transcript: [])
        try writeSession(in: temp, pid: 3, sessionID: "dead", transcript: [])

        let scanner = AgentScanner(paths: temp.paths, isAlive: { $0 != 3 })
        let sessions = await scanner.scan(now: referenceDate)
        #expect(sessions.map(\.id) == ["interactive"])
    }

    @Test func sortsSessionsThatNeedAttentionFirst() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, pid: 1, sessionID: "working", cwd: "/w/one", transcript: [try TranscriptFixture.userPrompt("go")])
        try writeSession(in: temp, pid: 2, sessionID: "blocked", cwd: "/w/two", transcript: [try TranscriptFixture.userPrompt("go")])
        try writeSession(in: temp, pid: 3, sessionID: "idle", cwd: "/w/three", status: "idle", transcript: [])

        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })
        await scanner.apply(HookEvent(kind: .permissionRequested, sessionID: "blocked", receivedAt: referenceDate))
        let sessions = await scanner.scan(now: referenceDate)
        #expect(sessions.map(\.id) == ["blocked", "working", "idle"])
    }

    @Test func sessionEndForgetsHookState() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        try writeSession(in: temp, transcript: [try TranscriptFixture.userPrompt("go")])
        let scanner = AgentScanner(paths: temp.paths, isAlive: { _ in true })

        await scanner.apply(HookEvent(kind: .permissionRequested, sessionID: "session-1", receivedAt: referenceDate))
        await scanner.apply(HookEvent(kind: .sessionEnd, sessionID: "session-1", receivedAt: referenceDate))
        let sessions = await scanner.scan(now: referenceDate)
        #expect(sessions.first?.status == .working)
    }
}
