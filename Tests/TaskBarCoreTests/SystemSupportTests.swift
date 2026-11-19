import Foundation
import Testing
@testable import TaskBarCore

@Suite("System process runner")
struct SystemProcessRunnerTests {
    @Test func feedsInputToTheCommandAndCapturesItsOutput() throws {
        let output = try ProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            input: Data("hello runner".utf8),
            timeout: 10
        )
        #expect(output.status == 0)
        #expect(!output.timedOut)
        #expect(output.standardOutput == Data("hello runner".utf8))
    }

    @Test func reportsExitStatusAndStandardError() throws {
        let output = try ProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo oops >&2; exit 3"],
            timeout: 10
        )
        #expect(output.status == 3)
        #expect(String(decoding: output.standardError, as: UTF8.self) == "oops\n")
    }

    @Test func stopsACommandThatRunsPastItsTimeout() throws {
        let started = Date()
        let output = try ProcessRunner.runBlocking(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.5
        )
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func throwsWhenTheExecutableCannotStart() {
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.runBlocking(
                executable: URL(fileURLWithPath: "/nonexistent/taskbar-tool"),
                arguments: [],
                timeout: 5
            )
        }
    }

    @Test func runsAsynchronouslyWithTheSameResult() async throws {
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["async"],
            timeout: 10
        )
        #expect(output.status == 0)
        #expect(String(decoding: output.standardOutput, as: UTF8.self) == "async\n")
    }
}

@Suite("System executable lookup")
struct SystemExecutableLookupTests {
    @Test func picksTheFirstExecutableCandidateInOrder() throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let fileManager = FileManager.default
        let plain = scratch.url.appendingPathComponent("plain")
        let tool = scratch.url.appendingPathComponent("tool")
        fileManager.createFile(atPath: plain.path, contents: Data("data".utf8), attributes: [.posixPermissions: 0o644])
        fileManager.createFile(atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let missing = scratch.url.appendingPathComponent("missing")
        #expect(ExecutableLocator.first(in: [missing, plain, tool]) == tool)
        #expect(ExecutableLocator.first(in: [plain]) == nil)
        #expect(ExecutableLocator.first(in: []) == nil)
    }
}
