import Foundation
import Testing
@testable import TaskBarCore

@Suite("Text polishing")
struct TextPolishingTests {
    @Test func usesDistinctInstructionsPerStyle() {
        let note = PolishInstructions.system(for: .note)
        let prompt = PolishInstructions.system(for: .prompt)

        #expect(note != prompt)
        #expect(note.contains("note editor"))
        #expect(prompt.contains("prompt engineer"))
        // Both must keep the user's language and refuse to act on the text.
        for instructions in [note, prompt] {
            #expect(instructions.contains("Never translate"))
            #expect(instructions.contains("never"))
            #expect(!instructions.contains("\\"))
        }
    }

    @Test func wrapsTheTextInAStyleSpecificTag() {
        #expect(PolishInstructions.userMessage(for: "buy milk", style: .note) == "<note>\nbuy milk\n</note>")
        #expect(PolishInstructions.userMessage(for: "build an app", style: .prompt) == "<draft>\nbuild an app\n</draft>")
        #expect(PolishInstructions.system(for: .note).contains("<note>"))
        #expect(PolishInstructions.system(for: .prompt).contains("<draft>"))
    }

    @Test func mapsNoteKindsToStyles() {
        #expect(PolishStyle(.note) == .note)
        #expect(PolishStyle(.prompt) == .prompt)
        #expect(PolishStyle.note.actionLabel == "Tidy up")
        #expect(PolishStyle.prompt.actionLabel == "Refine prompt")
    }

    @Test func cleansModelOutput() {
        #expect(PolishOutput.clean("  \n# Title\n\n- item\n\n") == "# Title\n\n- item")
        #expect(PolishOutput.clean("```markdown\n# Title\n- item\n```") == "# Title\n- item")
        #expect(PolishOutput.clean("<note>\n# Title\n</note>") == "# Title")
        #expect(PolishOutput.clean("<draft>Build it</draft>") == "Build it")
        // Code fences inside the text are content and must survive.
        let withCode = "Run this:\n\n```sh\nmake app\n```\n\nThen open it."
        #expect(PolishOutput.clean(withCode) == withCode)
    }

    @Test func buildsAnIsolatedHeadlessInvocation() throws {
        let arguments = ClaudeCLI.arguments(model: "haiku", systemPrompt: "SYSTEM", sessionID: "abc-123")
        #expect(arguments.first == "--print")
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--strict-mcp-config"))

        func value(after flag: String) throws -> String {
            let index = try #require(arguments.firstIndex(of: flag))
            return arguments[index + 1]
        }
        #expect(try value(after: "--model") == "haiku")
        #expect(try value(after: "--system-prompt") == "SYSTEM")
        // An empty tool list: the model can only answer with text.
        #expect(try value(after: "--tools") == "")
        #expect(try value(after: "--settings") == #"{"disableAllHooks":true}"#)
        #expect(try value(after: "--session-id") == "abc-123")
    }

    @Test func removesTheStubTheCommandLeavesBehind() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let projects = temp.url.appendingPathComponent("projects")
        let ownFolder = projects.appendingPathComponent("-tmp-tidy")
        let sharedFolder = projects.appendingPathComponent("-work-app")
        try FileManager.default.createDirectory(at: sharedFolder, withIntermediateDirectories: true)
        let unrelated = sharedFolder.appendingPathComponent("someone-elses-session.jsonl")
        try Data("keep me".utf8).write(to: unrelated)

        // A stand-in for the CLI: writes a title record named after the session ID it is given.
        let script = temp.url.appendingPathComponent("fake-claude")
        let source = """
        #!/bin/sh
        while [ $# -gt 0 ]; do
          if [ "$1" = "--session-id" ]; then session="$2"; fi
          shift
        done
        mkdir -p '\(ownFolder.path)'
        echo '{"type":"ai-title"}' > '\(ownFolder.path)'/"$session.jsonl"
        cat > /dev/null
        echo "rewritten"
        """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let polisher = ClaudeCLIPolisher(executable: script, projectsDirectory: projects)
        #expect(try await polisher.polish("hello", style: .note) == "rewritten")

        // The stub and its now-empty folder are gone; other sessions are untouched.
        #expect(!FileManager.default.fileExists(atPath: ownFolder.path))
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "keep me")
    }

    @Test func rejectsEmptyInputBeforeSpawningAnything() async {
        let polisher = ClaudeCLIPolisher(executable: URL(fileURLWithPath: "/nonexistent/claude"))
        await #expect(throws: TextPolishError.emptyInput) {
            try await polisher.polish("  \n ", style: .note)
        }
    }

    @Test func surfacesFailuresFromTheCommand() async throws {
        // `false` exits with status 1 and prints nothing.
        let polisher = ClaudeCLIPolisher(executable: URL(fileURLWithPath: "/usr/bin/false"))
        await #expect(throws: TextPolishError.self) {
            try await polisher.polish("some text", style: .note)
        }
    }

    @Test func returnsTheCommandOutput() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        // A stand-in for the CLI that echoes its input back inside a code fence.
        let script = temp.url.appendingPathComponent("fake-claude")
        try Data("#!/bin/sh\nprintf '```\\n'; cat; printf '\\n```\\n'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let polisher = ClaudeCLIPolisher(executable: script)
        let result = try await polisher.polish("hello world", style: .prompt)
        #expect(result == "<draft>\nhello world\n</draft>")
    }

    @Test func timesOutSlowCommands() async throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let script = temp.url.appendingPathComponent("slow-claude")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let polisher = ClaudeCLIPolisher(executable: script, timeout: 0.5)
        await #expect(throws: TextPolishError.timedOut) {
            try await polisher.polish("hello", style: .note)
        }
    }

    @Test func locatesTheCLIInKnownPlaces() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let fileManager = FileManager.default
        #expect(ClaudeCLILocator.candidates(home: temp.url, fileManager: fileManager).first?.path
            == temp.url.appendingPathComponent(".local/bin/claude").path)

        // Only an editor-bundled copy exists; the newest version wins.
        for version in ["2.1.9", "2.1.327", "2.1.40"] {
            let binary = temp.url.appendingPathComponent(
                ".vscode/extensions/anthropic.claude-code-\(version)-darwin-arm64/resources/native-binary/claude"
            )
            try fileManager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        let bundled = ClaudeCLILocator.candidates(home: temp.url, fileManager: fileManager)
            .first { $0.path.contains(".vscode") }
        #expect(bundled?.path.contains("2.1.327") == true)
    }
}

@Suite("Note chunker")
struct NoteChunkerTests {
    @Test func keepsShortTextWhole() {
        #expect(NoteChunker.chunks(of: "  short note \n", maxCharacters: 100) == ["short note"])
        #expect(NoteChunker.chunks(of: "   \n ", maxCharacters: 100).isEmpty)
    }

    @Test func splitsOnParagraphBoundaries() {
        let text = "aaaa aaaa\n\nbbbb bbbb\n\ncccc cccc"
        let chunks = NoteChunker.chunks(of: text, maxCharacters: 22)
        #expect(chunks == ["aaaa aaaa\n\nbbbb bbbb", "cccc cccc"])
        #expect(chunks.allSatisfy { $0.count <= 22 })
    }

    @Test func splitsAnOversizedParagraphAtWordBoundaries() {
        let paragraph = Array(repeating: "word", count: 20).joined(separator: " ")
        let chunks = NoteChunker.chunks(of: paragraph, maxCharacters: 24)
        #expect(chunks.allSatisfy { $0.count <= 24 })
        #expect(chunks.joined(separator: " ") == paragraph)
    }

    @Test func splitsAWordLongerThanTheLimit() {
        let chunks = NoteChunker.chunks(of: String(repeating: "x", count: 25), maxCharacters: 10)
        #expect(chunks.map(\.count) == [10, 10, 5])
    }
}

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test func parsesCommonBlocks() {
        let text = """
        # Release plan

        Ship **v1** this week.
        Second line of the paragraph.

        - first
          - nested
        * second
        1. step one
        2) step two
        > quoted
        ---
        """
        #expect(MarkdownBlockParser.parse(text) == [
            .heading(level: 1, text: "Release plan"),
            .paragraph("Ship **v1** this week.\nSecond line of the paragraph."),
            .bullet(text: "first", indent: 0),
            .bullet(text: "nested", indent: 1),
            .bullet(text: "second", indent: 0),
            .numbered(marker: "1.", text: "step one", indent: 0),
            .numbered(marker: "2.", text: "step two", indent: 0),
            .quote("quoted"),
            .divider
        ])
    }

    @Test func parsesCheckboxesWithTheirSourceLine() {
        let text = "Todo:\n- [ ] write docs\n- [x] add tests\n- [X] ship"
        #expect(MarkdownBlockParser.parse(text) == [
            .paragraph("Todo:"),
            .checkbox(text: "write docs", isChecked: false, indent: 0, line: 1),
            .checkbox(text: "add tests", isChecked: true, indent: 0, line: 2),
            .checkbox(text: "ship", isChecked: true, indent: 0, line: 3)
        ])
    }

    @Test func keepsCodeFencesVerbatim() {
        let text = "Before\n```swift\nlet x = 1\n# not a heading\n```\nAfter"
        #expect(MarkdownBlockParser.parse(text) == [
            .paragraph("Before"),
            .code("let x = 1\n# not a heading"),
            .paragraph("After")
        ])
        // An unterminated fence still shows its contents.
        #expect(MarkdownBlockParser.parse("```\nabc") == [.code("abc")])
    }

    @Test func doesNotMistakeProseForStructure() {
        #expect(MarkdownBlockParser.parse("#hashtag is not a heading") == [.paragraph("#hashtag is not a heading")])
        #expect(MarkdownBlockParser.parse("2026 was a good year") == [.paragraph("2026 was a good year")])
        #expect(MarkdownBlockParser.parse("-dash without space") == [.paragraph("-dash without space")])
    }

    @Test func stripsMarkersForPlainText() {
        #expect(MarkdownBlockParser.plainText(ofLine: "### Title") == "Title")
        #expect(MarkdownBlockParser.plainText(ofLine: "  - [x] done **now**") == "done now")
        #expect(MarkdownBlockParser.plainText(ofLine: "12. step") == "step")
        #expect(MarkdownBlockParser.plainText(ofLine: "```swift") == "")
        #expect(MarkdownBlockParser.plainText(ofLine: "---") == "")
        #expect(MarkdownBlockParser.plainText(ofLine: "plain 2026. text") == "plain 2026. text")
    }

    @Test func togglesACheckboxInPlace() {
        let text = "- [ ] one\n- [x] two\nplain"
        #expect(MarkdownBlockParser.togglingCheckbox(atLine: 0, in: text) == "- [x] one\n- [x] two\nplain")
        #expect(MarkdownBlockParser.togglingCheckbox(atLine: 1, in: text) == "- [ ] one\n- [ ] two\nplain")
        #expect(MarkdownBlockParser.togglingCheckbox(atLine: 2, in: text) == text)
        #expect(MarkdownBlockParser.togglingCheckbox(atLine: 9, in: text) == text)
    }
}

@Suite("Search")
struct SearchTests {
    private let tasks: [TaskItem] = [
        TaskItem(title: "Plan Q1 roadmap", children: [
            TaskItem(title: "Interview customers", notes: "Ask about onboarding friction and pricing."),
            TaskItem(title: "Draft proposal", isDone: true)
        ]),
        TaskItem(title: "Renovação do contrato")
    ]

    private let notes: [Note] = [
        Note(title: "Pricing ideas", body: "Tiered plans, annual discount."),
        Note(body: "Reunião com fornecedor\nDiscutir prazos de entrega.")
    ]

    @Test func findsNestedTasksWithTheirBreadcrumb() throws {
        let results = Search.run(query: "interview", tasks: tasks, notes: notes)
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.title == "Interview customers")
        #expect(result.subtitle == "Plan Q1 roadmap")
        guard case .task(let path) = result.target else {
            Issue.record("expected a task result")
            return
        }
        #expect(path == [tasks[0].id, tasks[0].children[0].id])
    }

    @Test func ignoresCaseAndAccents() {
        #expect(Search.run(query: "RENOVACAO", tasks: tasks, notes: notes).map(\.title) == ["Renovação do contrato"])
        #expect(Search.run(query: "reuniao", tasks: tasks, notes: notes).map(\.title) == ["Reunião com fornecedor"])
    }

    @Test func ranksTitleMatchesBeforeBodyMatches() {
        let results = Search.run(query: "pricing", tasks: tasks, notes: notes)
        #expect(results.map(\.title) == ["Pricing ideas", "Interview customers"])
        #expect(results[1].subtitle.localizedCaseInsensitiveContains("pricing"))
    }

    @Test func requiresEveryTermToMatch() {
        #expect(Search.run(query: "draft proposal", tasks: tasks, notes: notes).map(\.title) == ["Draft proposal"])
        #expect(Search.run(query: "draft roadmap", tasks: tasks, notes: notes).isEmpty)
        #expect(Search.run(query: "   ", tasks: tasks, notes: notes).isEmpty)
    }

    @Test func flagsCompletedTasksAndRespectsTheLimit() {
        #expect(Search.run(query: "draft", tasks: tasks, notes: notes).first?.isDone == true)
        let many = (0..<50).map { TaskItem(title: "item \($0)") }
        #expect(Search.run(query: "item", tasks: many, notes: [], limit: 10).count == 10)
    }

    @Test func buildsASnippetAroundTheMatch() {
        let text = String(repeating: "lorem ", count: 30) + "needle" + String(repeating: " ipsum", count: 30)
        let snippet = Search.snippet(of: text, around: "needle", radius: 10)
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.contains("needle"))
        #expect(snippet.count < 40)
    }
}
