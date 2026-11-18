import Foundation

/// A live Claude Code session as shown in the Agents tab.
public struct AgentSession: Identifiable, Equatable, Sendable {
    /// The Claude Code session ID.
    public var id: String
    public var pid: Int32
    public var cwd: String
    public var registryName: String?
    public var entrypoint: String?
    public var title: String?
    public var status: AgentStatus
    public var statusDetail: String?
    public var lastPrompt: String?
    public var lastAssistantText: String?
    public var gitBranch: String?
    public var model: String?
    public var startedAt: Date?
    public var lastActivity: Date?
    public var entries: [TranscriptEntry]
    public var transcriptURL: URL?

    public init(
        id: String,
        pid: Int32,
        cwd: String,
        registryName: String? = nil,
        entrypoint: String? = nil,
        title: String? = nil,
        status: AgentStatus = .idle,
        statusDetail: String? = nil,
        lastPrompt: String? = nil,
        lastAssistantText: String? = nil,
        gitBranch: String? = nil,
        model: String? = nil,
        startedAt: Date? = nil,
        lastActivity: Date? = nil,
        entries: [TranscriptEntry] = [],
        transcriptURL: URL? = nil
    ) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.registryName = registryName
        self.entrypoint = entrypoint
        self.title = title
        self.status = status
        self.statusDetail = statusDetail
        self.lastPrompt = lastPrompt
        self.lastAssistantText = lastAssistantText
        self.gitBranch = gitBranch
        self.model = model
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.entries = entries
        self.transcriptURL = transcriptURL
    }

    /// Folder name of the working directory, e.g. `task-bar`.
    public var projectName: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Best available one-line description of the conversation.
    public var displayTitle: String {
        title ?? lastPrompt?.split(whereSeparator: \.isNewline).first.map(String.init) ?? registryName ?? "New session"
    }

    /// Whether the session runs inside an editor extension rather than a terminal.
    public var runsInIDE: Bool {
        guard let entrypoint else { return false }
        return entrypoint.contains("vscode") || entrypoint.contains("jetbrains") || entrypoint.contains("ide")
    }

    /// Shell command that reopens this conversation.
    public var resumeCommand: String {
        "cd \(Self.shellQuoted(cwd)) && claude --resume \(id)"
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
