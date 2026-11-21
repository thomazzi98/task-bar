import Foundation

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

    public func polish(_ text: String, style: PolishStyle) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextPolishError.emptyInput }

        let answer: String
        do {
            answer = try await ClaudeCLI.answer(
                executable: executable,
                model: model,
                systemPrompt: PolishInstructions.system(for: style),
                input: PolishInstructions.userMessage(for: trimmed, style: style),
                timeout: timeout,
                projectsDirectory: projectsDirectory
            )
        } catch ClaudeCLI.Failure.timedOut {
            throw TextPolishError.timedOut
        } catch ClaudeCLI.Failure.failed(let reason) {
            throw TextPolishError.failed(reason)
        }

        let cleaned = PolishOutput.clean(answer)
        guard !cleaned.isEmpty else { throw TextPolishError.failed("The model returned an empty answer.") }
        return cleaned
    }
}
