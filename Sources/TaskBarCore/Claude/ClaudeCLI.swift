import Foundation

/// Finds the Claude Code command-line binary on this machine.
public enum ClaudeCLILocator {
    public static func locate(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        ExecutableLocator.first(in: candidates(home: home, fileManager: fileManager), fileManager: fileManager)
    }

    static func candidates(home: URL, fileManager: FileManager) -> [URL] {
        var urls = [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude")
        ]
        // Editor extensions bundle their own copy; prefer the most recently installed.
        for editor in [".vscode", ".vscode-insiders", ".cursor", ".windsurf"] {
            let extensions = home.appendingPathComponent("\(editor)/extensions")
            let bundled = ((try? fileManager.contentsOfDirectory(atPath: extensions.path)) ?? [])
                .filter { $0.hasPrefix("anthropic.claude-code-") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { extensions.appendingPathComponent("\($0)/resources/native-binary/claude") }
            urls.append(contentsOf: bundled)
        }
        return urls
    }
}

/// Runs the Claude Code CLI headless: one isolated turn that reads standard input and prints an answer.
///
/// This reuses the login Claude Code already has, so there is no API key to paste or store.
/// The run is isolated: no tools, no hooks, no MCP servers and no saved session. Nothing is left
/// behind on disk: the session stub the CLI writes is removed, and the process runner removes its
/// own scratch files on every path.
public enum ClaudeCLI {
    public enum Failure: LocalizedError, Equatable {
        case timedOut
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .timedOut: "The model took too long to answer. Try again."
            case .failed(let reason): reason
            }
        }
    }

    public static func arguments(model: String, systemPrompt: String, sessionID: String) -> [String] {
        [
            "--print",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--tools", "",
            "--session-id", sessionID,
            "--no-session-persistence",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--settings", #"{"disableAllHooks":true}"#
        ]
    }

    /// Sends `input` on standard input and returns what Claude printed, trimmed.
    ///
    /// - Parameter projectsDirectory: Claude Code's `projects` folder. When given, the session stub
    ///   of this run is removed afterwards.
    public static func answer(
        executable: URL,
        model: String,
        systemPrompt: String,
        input: String,
        timeout: TimeInterval,
        projectsDirectory: URL?
    ) async throws -> String {
        let sessionID = UUID().uuidString.lowercased()
        defer {
            if let projectsDirectory {
                removeSessionStub(sessionID: sessionID, projectsDirectory: projectsDirectory)
            }
        }

        let output = try await ProcessRunner.run(
            executable: executable,
            arguments: arguments(model: model, systemPrompt: systemPrompt, sessionID: sessionID),
            input: Data(input.utf8),
            // A neutral directory keeps project-specific instructions out of the request.
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout
        )

        if output.timedOut { throw Failure.timedOut }
        let answer = String(decoding: output.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !answer.isEmpty else {
            let stderr = String(decoding: output.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = stderr.isEmpty ? answer : stderr
            throw Failure.failed(
                reason.isEmpty ? "Claude Code exited with status \(output.status)." : String(reason.prefix(300))
            )
        }
        return answer
    }

    /// Even with persistence off, the CLI writes a one-line title record for the session.
    /// The session ID is ours, so that file can be found and removed precisely.
    static func removeSessionStub(sessionID: String, projectsDirectory: URL) {
        let fileManager = FileManager.default
        let locator = TranscriptLocator(projectsDirectory: projectsDirectory)
        guard let stub = locator.transcriptURL(sessionID: sessionID, cwd: "") else { return }
        try? fileManager.removeItem(at: stub)

        // Drop the per-directory folder too, but only when nothing else lives in it.
        let folder = stub.deletingLastPathComponent()
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
    }
}
