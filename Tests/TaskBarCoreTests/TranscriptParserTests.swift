import Foundation
import Testing
@testable import TaskBarCore

@Suite("Transcript parser")
struct TranscriptParserTests {
    @Test func summarizesAFinishedTurn() throws {
        let summary = TranscriptParser.summarize(lines: [
            TranscriptFixture.raw(#"{"type":"ai-title","aiTitle":"Fix the login bug","sessionId":"s1"}"#),
            try TranscriptFixture.userPrompt("the login page crashes on submit"),
            try TranscriptFixture.toolUse(id: "t1", name: "Read", input: ["file_path": "/repo/src/Login.swift"]),
            try TranscriptFixture.toolResult(for: "t1"),
            try TranscriptFixture.assistantText("Fixed: the form now validates before submitting.", timestamp: "2026-11-17T15:01:00.000Z")
        ])

        #expect(summary.title == "Fix the login bug")
        #expect(summary.lastPrompt == "the login page crashes on submit")
        #expect(summary.lastAssistantText == "Fixed: the form now validates before submitting.")
        #expect(summary.lastStopReason == "end_turn")
        #expect(summary.pendingTools.isEmpty)
        #expect(summary.gitBranch == "main")
        #expect(summary.model == "claude-opus-5-5")
        #expect(summary.hasConversation)
        #expect(summary.entries.map(\.kind) == [.userPrompt, .toolUse(name: "Read"), .assistantText])
        #expect(summary.entries[1].text == "Login.swift")

        let expected = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-11-17T15:01:00.000Z")
        #expect(summary.lastActivity == expected)
    }

    @Test func reportsAToolCallWithoutAResultAsPending() throws {
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.userPrompt("run the tests"),
            try TranscriptFixture.toolUse(
                id: "t1",
                name: "Bash",
                input: ["command": "swift test", "description": "Run the test suite"]
            )
        ])

        #expect(summary.pendingTools == [PendingTool(id: "t1", name: "Bash", summary: "Run the test suite")])
        #expect(summary.pendingTools.first?.displayText == "Bash: Run the test suite")
        #expect(summary.lastStopReason == "tool_use")
    }

    @Test func keepsUnfinishedParallelToolCallsPending() throws {
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.userPrompt("check both files"),
            try TranscriptFixture.toolUse(id: "a", name: "Read", input: ["file_path": "/x/A.swift"], messageID: "m1"),
            try TranscriptFixture.toolUse(id: "b", name: "Bash", input: ["command": "make build"], messageID: "m1"),
            try TranscriptFixture.toolResult(for: "a")
        ])
        #expect(summary.pendingTools.map(\.id) == ["b"])
    }

    @Test func ignoresStaleToolCallsFromEarlierMessages() throws {
        // "old" never got a result (e.g. it fell outside the bytes that were read), but the
        // conversation has clearly moved on to a newer assistant message.
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.toolUse(id: "old", name: "Bash", input: ["command": "ls"], messageID: "m1"),
            try TranscriptFixture.toolUse(id: "new", name: "Edit", input: ["file_path": "/x/B.swift"], messageID: "m2"),
            try TranscriptFixture.toolResult(for: "new")
        ])
        #expect(summary.pendingTools.isEmpty)
    }

    @Test func dropsPendingToolsOnceTheUserTypesAgain() throws {
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.toolUse(id: "t1", name: "Bash", input: ["command": "sleep 100"]),
            try TranscriptFixture.userPrompt("[Request interrupted by user]")
        ])
        #expect(summary.pendingTools.isEmpty)
    }

    @Test func recognisesQuestionsForTheUser() throws {
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.userPrompt("add a cache"),
            try TranscriptFixture.toolUse(
                id: "q1",
                name: "AskUserQuestion",
                input: ["questions": [["question": "Redis or in-memory?", "header": "Cache"]]]
            )
        ])
        let pending = try #require(summary.pendingTools.first)
        #expect(pending.asksTheUser)
        #expect(pending.summary == "Redis or in-memory?")

        let plan = TranscriptParser.summarize(lines: [try TranscriptFixture.toolUse(id: "p1", name: "ExitPlanMode")])
        #expect(plan.pendingTools.first?.summary == "Plan ready for review")
        #expect(plan.pendingTools.first?.asksTheUser == true)
    }

    @Test func skipsSubagentAndMachineGeneratedRecords() throws {
        let summary = TranscriptParser.summarize(lines: [
            try TranscriptFixture.userPrompt("real prompt"),
            try TranscriptFixture.userPrompt("subagent prompt", extra: ["isSidechain": true]),
            try TranscriptFixture.assistantText("subagent answer", extra: ["isSidechain": true]),
            try TranscriptFixture.userPrompt("<task-notification>\n<task-id>abc</task-id>"),
            try TranscriptFixture.userPrompt("injected", extra: ["promptSource": "system"]),
            try TranscriptFixture.userPrompt("meta", extra: ["isMeta": true])
        ])
        #expect(summary.entries.map(\.text) == ["real prompt"])
        #expect(summary.lastPrompt == "real prompt")
    }

    @Test func readsTypedTextBlocksAndIgnoresInjectedOnes() throws {
        let line = try TranscriptFixture.line([
            "type": "user",
            "uuid": "u1",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "<ide_selection>some code</ide_selection>"],
                    ["type": "text", "text": "explain this function"]
                ]
            ]
        ])
        let summary = TranscriptParser.summarize(lines: [line])
        #expect(summary.entries.map(\.text) == ["explain this function"])
        #expect(summary.entries.first?.id == "u1#1")
    }

    @Test func skipsBookkeepingRecordsWithoutDecodingThem() {
        let summary = TranscriptParser.summarize(lines: [
            // Would count as an assistant message if it were decoded and trusted.
            TranscriptFixture.raw(#"{"type":"api-request-blob","message":{"role":"assistant","content":[{"type":"text","text":"SHOULD NOT APPEAR"}]}}"#),
            TranscriptFixture.raw(#"{"type":"file-history-snapshot","snapshot":{}}"#),
            TranscriptFixture.raw("not json at all"),
            TranscriptFixture.raw(#"{"type":"last-prompt","lastPrompt":"resume the migration","sessionId":"s1"}"#)
        ])
        #expect(summary.entries.isEmpty)
        #expect(summary.lastAssistantText == nil)
        #expect(summary.lastPrompt == "resume the migration")
        #expect(summary.hasConversation)
    }

    @Test func prefersACustomTitleOverTheGeneratedOne() {
        let summary = TranscriptParser.summarize(lines: [
            TranscriptFixture.raw(#"{"type":"ai-title","aiTitle":"Generated"}"#),
            TranscriptFixture.raw(#"{"type":"custom-title","customTitle":"Mine"}"#)
        ])
        #expect(summary.title == "Mine")
    }

    @Test func capsTheNumberOfEntries() throws {
        let lines = try (0..<(TranscriptParser.entryLimit + 25)).map { index in
            try TranscriptFixture.userPrompt("prompt \(index)")
        }
        let summary = TranscriptParser.summarize(lines: lines)
        #expect(summary.entries.count == TranscriptParser.entryLimit)
        #expect(summary.entries.last?.text == "prompt \(TranscriptParser.entryLimit + 24)")
        #expect(summary.entries.first?.text == "prompt 25")
    }

    @Test func describesToolCalls() {
        #expect(TranscriptParser.toolSummary(name: "Bash", input: ["command": "git status\necho done"]) == "git status")
        #expect(TranscriptParser.toolSummary(name: "Write", input: ["file_path": "/a/b/README.md"]) == "README.md")
        #expect(TranscriptParser.toolSummary(name: "Grep", input: ["pattern": "TODO"]) == "TODO")
        #expect(TranscriptParser.toolSummary(name: "WebFetch", input: ["url": "https://example.com/docs"]) == "example.com")
        #expect(TranscriptParser.toolSummary(name: "Agent", input: ["description": "Explore the repo"]) == "Explore the repo")
        #expect(TranscriptParser.toolSummary(name: "mcp__custom__tool", input: [:]) == "")
    }
}

@Suite("Transcript reading")
struct TranscriptReaderTests {
    @Test func readsTheWholeFileWhenItFitsTheWindow() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("session.jsonl")
        try Data("first\nsecond\nthird\n".utf8).write(to: url)

        let lines = try TranscriptTailReader.readTailLines(of: url, maxBytes: 1024)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["first", "second", "third"])
    }

    @Test func dropsTheLineCutByTheWindowStart() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("session.jsonl")
        try Data("first-line\nsecond-line\nthird-line\n".utf8).write(to: url)

        // The last 16 bytes begin in the middle of "second-line".
        let lines = try TranscriptTailReader.readTailLines(of: url, maxBytes: 16)
        #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["third-line"])
    }

    @Test func widensTheWindowPastAnOversizedTrailingRecord() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("session.jsonl")

        var lines = try (0..<8).map { try TranscriptFixture.userPrompt("prompt \($0)") }
        let padding = String(repeating: "x", count: TranscriptTailReader.defaultWindow + 4096)
        lines.append(TranscriptFixture.raw(#"{"type":"api-request-blob","payload":"\#(padding)"}"#))
        try Data.jsonLines(lines).write(to: url)

        // The default window lands entirely inside the huge record and sees no conversation.
        let narrow = TranscriptParser.summarize(lines: try TranscriptTailReader.readTailLines(of: url))
        #expect(narrow.entries.isEmpty)

        let summary = try TranscriptTailReader.summarize(url)
        #expect(summary.entries.count == 8)
        #expect(summary.lastPrompt == "prompt 7")
    }

    @Test func encodesProjectFolderNamesLikeClaudeCode() {
        #expect(
            TranscriptLocator.encodedProjectName(for: "/Users/jane.doe/Documents/my_app/task-bar")
                == "-Users-jane-doe-Documents-my-app-task-bar"
        )
    }

    @Test func locatesTranscriptsEvenAfterTheSessionChangedDirectory() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let projects = temp.paths.claudeProjectsDirectory
        let locator = TranscriptLocator(projectsDirectory: projects)
        let fileManager = FileManager.default

        let direct = projects.appendingPathComponent("-work-app/session-1.jsonl")
        try fileManager.createDirectory(at: direct.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: direct)
        let expectedPath = direct.resolvingSymlinksInPath().path

        let found = locator.transcriptURL(sessionID: "session-1", cwd: "/work/app")
        #expect(found?.resolvingSymlinksInPath().path == expectedPath)

        // The session now reports a sub-directory, but its transcript stays where it started.
        let relocated = locator.transcriptURL(sessionID: "session-1", cwd: "/work/app/packages/core")
        #expect(relocated?.resolvingSymlinksInPath().path == expectedPath)
        #expect(locator.transcriptURL(sessionID: "missing", cwd: "/work/app") == nil)
    }
}
