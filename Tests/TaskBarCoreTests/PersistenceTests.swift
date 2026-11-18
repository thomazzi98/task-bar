import Foundation
import Testing
@testable import TaskBarCore

@Suite("Persistence")
struct PersistenceTests {
    private func sampleDocument() -> TaskDocument {
        let child = TaskItem(
            title: "Write tests",
            notes: "Cover the **tree** and the parser.",
            isDone: true,
            priority: .high,
            createdAt: referenceDate,
            completedAt: referenceDate
        )
        let root = TaskItem(title: "Release 1.0 #work", createdAt: referenceDate, children: [child])
        return TaskDocument(tasks: [root])
    }

    @Test func roundTripsTheTaskTree() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<TaskDocument>(url: temp.paths.tasksFile)
        let document = sampleDocument()

        try store.save(document)
        #expect(try store.load() == document)
    }

    @Test func missingFileLoadsAsNil() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<TaskDocument>(url: temp.paths.tasksFile)
        #expect(try store.load() == nil)
        #expect(store.loadOrRecover(default: TaskDocument()).document == TaskDocument())
    }

    @Test func createsIntermediateDirectoriesOnSave() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.url.appendingPathComponent("a/b/c/tasks.json")
        try JSONFileStore<TaskDocument>(url: url).save(sampleDocument())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func writesHumanReadableJSON() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<TaskDocument>(url: temp.paths.tasksFile)
        try store.save(sampleDocument())

        let text = try String(contentsOf: temp.paths.tasksFile, encoding: .utf8)
        #expect(text.contains("\n"))
        #expect(text.contains("\"title\" : \"Write tests\""))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"priority\" : \"high\""))
        // Dates are ISO 8601, not opaque numbers.
        #expect(text.contains("\"createdAt\" : \"2026-"))
    }

    @Test func quarantinesACorruptFileInsteadOfOverwritingIt() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.paths.tasksFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: url)

        let store = JSONFileStore<TaskDocument>(url: url)
        let outcome = store.loadOrRecover(default: TaskDocument())

        #expect(outcome.document == TaskDocument())
        #expect(outcome.failureDescription != nil)
        let quarantined = try #require(outcome.quarantinedFile)
        #expect(quarantined.lastPathComponent.hasPrefix("tasks.corrupt-"))
        #expect(try String(contentsOf: quarantined, encoding: .utf8) == "{ this is not json")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func toleratesHandEditedFilesWithMissingKeys() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let url = temp.paths.tasksFile
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = #"{"schemaVersion":1,"tasks":[{"title":"Minimal","children":[{"title":"Child"}]}]}"#
        try Data(json.utf8).write(to: url)

        let loaded = try JSONFileStore<TaskDocument>(url: url).load()
        let task = try #require(loaded?.tasks.first)
        #expect(task.title == "Minimal")
        #expect(!task.isDone)
        #expect(task.priority == .none)
        #expect(task.children.map(\.title) == ["Child"])
    }

    @Test func unknownPriorityFallsBackToNone() throws {
        let json = #"{"title":"Odd","priority":"urgent-ish"}"#
        let task = try JSONFileStore<TaskItem>.makeDecoder().decode(TaskItem.self, from: Data(json.utf8))
        #expect(task.priority == .none)
        #expect(TaskPriority.high > .medium)
        #expect(TaskPriority.allCases.sorted() == [.none, .low, .medium, .high])
    }

    @Test func roundTripsNotesIncludingKind() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<NotesDocument>(url: temp.paths.notesFile)
        let document = NotesDocument(notes: [
            Note(title: "Ideas", body: "First line", isPinned: true, createdAt: referenceDate),
            Note(body: "Build a CLI", kind: .prompt, createdAt: referenceDate)
        ])

        try store.save(document)
        #expect(try store.load() == document)
    }

    @Test func unknownNoteKindFallsBackToNote() throws {
        let json = #"{"title":"Legacy","kind":"something-else"}"#
        let note = try JSONFileStore<Note>.makeDecoder().decode(Note.self, from: Data(json.utf8))
        #expect(note.kind == .note)
        #expect(note.title == "Legacy")
    }
}

@Suite("Notes")
struct NoteTests {
    @Test func usesExplicitTitleWhenPresent() {
        let note = Note(title: "  Standup  ", body: "Line one\nLine two")
        #expect(note.displayTitle == "Standup")
        #expect(note.preview == "Line one · Line two")
    }

    @Test func fallsBackToFirstBodyLine() {
        let note = Note(body: "\n# Roadmap\n\nQ1 goals\nQ2 goals")
        #expect(note.displayTitle == "Roadmap")
        #expect(note.preview == "Q1 goals · Q2 goals")
    }

    @Test func previewsHideMarkdownSyntax() {
        let note = Note(title: "Plan", body: "## Goal\n- [ ] Ship **v1**\n- [x] Write `README`\n> see [the spec](https://example.com)\n---\n1. first")
        #expect(note.preview == "Goal · Ship v1 · Write README · see the spec · first")
    }

    @Test func namesEmptyNotesByKind() {
        #expect(Note().displayTitle == "Untitled note")
        #expect(Note(kind: .prompt).displayTitle == "Untitled prompt")
        #expect(Note().isEmpty)
        #expect(!Note(body: "x").isEmpty)
    }
}

@Suite("App paths")
struct AppPathsTests {
    @Test func usesStandardLocationsByDefault() {
        let paths = AppPaths.live(environment: [:])
        #expect(paths.supportDirectory.path.hasSuffix("/Library/Application Support/TaskBar"))
        #expect(paths.claudeDirectory.path.hasSuffix("/.claude"))
        #expect(paths.tasksFile.lastPathComponent == "tasks.json")
        #expect(paths.notesFile.lastPathComponent == "notes.json")
        #expect(paths.hookPIDFile.path.hasSuffix("/TaskBar/hook-events/.pid"))
        #expect(paths.claudeSessionsDirectory.path.hasSuffix("/.claude/sessions"))
    }

    @Test func honoursDirectoryOverrides() {
        let paths = AppPaths.live(environment: [
            "TASKBAR_DATA_DIR": "/tmp/taskbar-scratch",
            "TASKBAR_CLAUDE_DIR": "/tmp/claude-scratch"
        ])
        #expect(paths.supportDirectory.path == "/tmp/taskbar-scratch")
        #expect(paths.hookScript.path == "/tmp/taskbar-scratch/hooks/taskbar-hook.sh")
        #expect(paths.claudeSettingsFile.path == "/tmp/claude-scratch/settings.json")
    }

    @Test func followsClaudeCodesOwnConfigVariable() {
        let paths = AppPaths.live(environment: ["CLAUDE_CONFIG_DIR": "/opt/claude-config"])
        #expect(paths.claudeDirectory.path == "/opt/claude-config")
        // TaskBar's own variable wins when both are set.
        let both = AppPaths.live(environment: ["CLAUDE_CONFIG_DIR": "/a", "TASKBAR_CLAUDE_DIR": "/b"])
        #expect(both.claudeDirectory.path == "/b")
        #expect(AppPaths.live(environment: ["TASKBAR_DATA_DIR": ""]).supportDirectory.lastPathComponent == "TaskBar")
    }
}
