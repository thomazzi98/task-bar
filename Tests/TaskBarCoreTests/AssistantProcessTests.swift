import Foundation
import Testing
@testable import TaskBarCore

/// The assistant sends the machine snapshot through a child process. Nothing from that run may
/// stay on disk, whichever way the run ends.
@Suite("Assistant process scratch cleanup")
struct AssistantProcessScratchTests {
    private func scratchEntries(in root: TemporaryDirectory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.url.path)
    }

    @Test func scratchFolderIsRemovedWhenTheCommandFails() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }

        let output = try ProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat >/dev/null; echo oops >&2; exit 3"],
            input: Data("snapshot".utf8),
            timeout: 10,
            scratchRoot: root.url
        )

        #expect(output.status == 3)
        #expect(try scratchEntries(in: root).isEmpty)
    }

    @Test func scratchFolderIsRemovedWhenTheCommandTimesOut() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }

        let output = try ProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "cat >/dev/null; sleep 30"],
            input: Data("snapshot".utf8),
            timeout: 0.5,
            scratchRoot: root.url
        )

        #expect(output.timedOut)
        #expect(try scratchEntries(in: root).isEmpty)
    }

    @Test func scratchFolderIsRemovedWhenTheCommandCannotStart() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }

        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.runBlocking(
                executable: URL(fileURLWithPath: "/nonexistent/claude"),
                arguments: [],
                input: Data("snapshot".utf8),
                timeout: 10,
                scratchRoot: root.url
            )
        }
        #expect(try scratchEntries(in: root).isEmpty)
    }
}
