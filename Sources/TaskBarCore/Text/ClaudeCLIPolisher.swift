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

/// Rewrites text with a small Claude model by running the Claude Code CLI in headless mode.
///
/// This reuses the login Claude Code already has, so there is no API key to paste or store.
/// The run is isolated: no tools, no hooks, no MCP servers and no saved session.
public struct ClaudeCLIPolisher: TextPolisher {
    public let executable: URL
    public let model: String
    public let timeout: TimeInterval
    /// Claude Code's `projects` folder, used to remove the stub a headless run leaves behind.
    public let projectsDirectory: URL?

    public init(
        executable: URL,
        model: String = "haiku",
        timeout: TimeInterval = 120,
        projectsDirectory: URL? = nil
    ) {
        self.executable = executable
        self.model = model
        self.timeout = timeout
        self.projectsDirectory = projectsDirectory
    }

    public var name: String { "Claude (\(model))" }

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

    public func polish(_ text: String, style: PolishStyle) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextPolishError.emptyInput }

        let sessionID = UUID().uuidString.lowercased()
        defer {
            if let projectsDirectory {
                Self.removeSessionStub(sessionID: sessionID, projectsDirectory: projectsDirectory)
            }
        }

        let output = try await ProcessRunner.run(
            executable: executable,
            arguments: Self.arguments(
                model: model,
                systemPrompt: PolishInstructions.system(for: style),
                sessionID: sessionID
            ),
            input: Data(PolishInstructions.userMessage(for: trimmed, style: style).utf8),
            // A neutral directory keeps project-specific instructions out of the request.
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: timeout
        )

        if output.timedOut { throw TextPolishError.timedOut }
        let answer = PolishOutput.clean(String(decoding: output.standardOutput, as: UTF8.self))
        guard output.status == 0, !answer.isEmpty else {
            let stderr = String(decoding: output.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = stderr.isEmpty ? answer : stderr
            throw TextPolishError.failed(
                reason.isEmpty ? "Claude Code exited with status \(output.status)." : String(reason.prefix(300))
            )
        }
        return answer
    }
}
