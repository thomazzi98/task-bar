import Foundation

/// One displayable step of a Claude Code conversation.
public struct TranscriptEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case userPrompt
        case assistantText
        case toolUse(name: String)
    }

    public var id: String
    public var kind: Kind
    public var text: String
    public var timestamp: Date?

    public init(id: String, kind: Kind, text: String, timestamp: Date? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.timestamp = timestamp
    }
}

/// A tool call the model issued that has no result yet: it is either running or waiting for
/// the user to approve or answer it.
public struct PendingTool: Equatable, Sendable {
    public var id: String
    public var name: String
    public var summary: String

    public init(id: String, name: String, summary: String) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    /// Tools that always block on a human reply rather than on a permission decision.
    public var asksTheUser: Bool {
        name == "AskUserQuestion" || name == "ExitPlanMode"
    }

    public var displayText: String {
        summary.isEmpty ? name : "\(name): \(summary)"
    }
}

/// What the app needs to know about the recent part of a session transcript.
public struct TranscriptSummary: Equatable, Sendable {
    public var title: String?
    public var lastPrompt: String?
    public var lastAssistantText: String?
    /// Recent conversation steps in chronological order.
    public var entries: [TranscriptEntry]
    public var pendingTools: [PendingTool]
    public var lastStopReason: String?
    public var lastActivity: Date?
    public var gitBranch: String?
    public var model: String?

    public init(
        title: String? = nil,
        lastPrompt: String? = nil,
        lastAssistantText: String? = nil,
        entries: [TranscriptEntry] = [],
        pendingTools: [PendingTool] = [],
        lastStopReason: String? = nil,
        lastActivity: Date? = nil,
        gitBranch: String? = nil,
        model: String? = nil
    ) {
        self.title = title
        self.lastPrompt = lastPrompt
        self.lastAssistantText = lastAssistantText
        self.entries = entries
        self.pendingTools = pendingTools
        self.lastStopReason = lastStopReason
        self.lastActivity = lastActivity
        self.gitBranch = gitBranch
        self.model = model
    }

    public static let empty = TranscriptSummary()

    public var hasConversation: Bool {
        !entries.isEmpty || lastPrompt != nil
    }
}
