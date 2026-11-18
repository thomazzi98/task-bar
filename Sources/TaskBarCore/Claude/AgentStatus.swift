import Foundation

/// What a Claude Code session is doing, from the user's point of view.
public enum AgentStatus: String, Sendable, CaseIterable {
    /// Blocked on a permission dialog.
    case needsApproval
    /// Blocked on a question, a plan review or other free-form input.
    case needsAnswer
    case working
    /// Finished a turn the user has not looked at yet.
    case finished
    case idle

    /// The session cannot make progress until the user acts.
    public var needsAttention: Bool {
        self == .needsApproval || self == .needsAnswer
    }

    public var label: String {
        switch self {
        case .needsApproval: "Needs approval"
        case .needsAnswer: "Needs your answer"
        case .working: "Working"
        case .finished: "Finished"
        case .idle: "Idle"
        }
    }

    /// Lower values sort first in the agents list.
    public var sortRank: Int {
        switch self {
        case .needsApproval: 0
        case .needsAnswer: 1
        case .working: 2
        case .finished: 3
        case .idle: 4
        }
    }
}

public struct ResolvedAgentStatus: Equatable, Sendable {
    public var status: AgentStatus
    public var detail: String?

    public init(status: AgentStatus, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }
}

/// Everything known about a session at one moment, from the three available signals.
public struct AgentStatusInput: Sendable {
    // Registry file (`~/.claude/sessions/<pid>.json`)
    public var registryStatus: String?
    public var waitingFor: String?
    public var registryUpdatedAt: Date?
    public var statusUpdatedAt: Date?
    // Hook stream
    public var hookPhase: HookPhase?
    // Transcript tail
    public var pendingTools: [PendingTool]
    public var lastStopReason: String?
    public var lastActivity: Date?
    public var hasConversation: Bool
    // App state
    public var acknowledgedAt: Date?
    public var now: Date

    public init(
        registryStatus: String? = nil,
        waitingFor: String? = nil,
        registryUpdatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil,
        hookPhase: HookPhase? = nil,
        pendingTools: [PendingTool] = [],
        lastStopReason: String? = nil,
        lastActivity: Date? = nil,
        hasConversation: Bool = false,
        acknowledgedAt: Date? = nil,
        now: Date = Date()
    ) {
        self.registryStatus = registryStatus
        self.waitingFor = waitingFor
        self.registryUpdatedAt = registryUpdatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.hookPhase = hookPhase
        self.pendingTools = pendingTools
        self.lastStopReason = lastStopReason
        self.lastActivity = lastActivity
        self.hasConversation = hasConversation
        self.acknowledgedAt = acknowledgedAt
        self.now = now
    }
}

/// Decides a session's status by combining the registry, the hook stream and the transcript.
///
/// The signals overlap on purpose: hooks are instant but optional, the registry is always
/// present but coarse, and the transcript knows exactly which tool call is outstanding.
public enum AgentStatusResolver {
    /// Without a registry status or hooks, a session that wrote to its transcript this recently
    /// is assumed to still be working.
    static let recentActivityWindow: TimeInterval = 20
    /// Slack allowed between a hook event and the registry update describing the same moment.
    static let registryLag: TimeInterval = 0.5

    public static func resolve(_ input: AgentStatusInput) -> ResolvedAgentStatus {
        let question = input.pendingTools.first(where: \.asksTheUser)

        // 1. The registry says the session is blocked on the user right now.
        if let waitingFor = input.waitingFor {
            if let question {
                return ResolvedAgentStatus(status: .needsAnswer, detail: question.summary)
            }
            if case .awaitingApproval(let detail, _) = input.hookPhase {
                return ResolvedAgentStatus(status: .needsApproval, detail: detail)
            }
            if case .awaitingInput(let detail, _) = input.hookPhase {
                return ResolvedAgentStatus(status: .needsAnswer, detail: detail)
            }
            if waitingFor.localizedCaseInsensitiveContains("input") {
                return ResolvedAgentStatus(status: .needsAnswer, detail: nil)
            }
            return ResolvedAgentStatus(status: .needsApproval, detail: input.pendingTools.last?.displayText)
        }

        // 2. A hook reported a dialog and the registry has not moved on since.
        if let phase = input.hookPhase, !registryMovedOn(since: phase.since, input: input) {
            switch phase {
            case .awaitingApproval(let detail, _):
                return ResolvedAgentStatus(
                    status: .needsApproval,
                    detail: detail ?? input.pendingTools.last?.displayText
                )
            case .awaitingInput(let detail, _):
                return ResolvedAgentStatus(status: .needsAnswer, detail: detail ?? question?.summary)
            case .working, .stopped:
                break
            }
        }

        // 3. The transcript ends on a question nobody has answered.
        if let question {
            return ResolvedAgentStatus(status: .needsAnswer, detail: question.summary)
        }

        // 4. Busy or not.
        if isBusy(input) {
            return ResolvedAgentStatus(status: .working, detail: input.pendingTools.last?.displayText)
        }

        // 5. Not busy: a turn the user has not seen yet counts as "finished".
        guard input.hasConversation, let finishedAt = finishedAt(input) else {
            return ResolvedAgentStatus(status: .idle)
        }
        let isUnseen = finishedAt > (input.acknowledgedAt ?? .distantPast)
        return ResolvedAgentStatus(status: isUnseen ? .finished : .idle)
    }

    /// The registry changed after the hook fired and no longer reports a wait, which means the
    /// dialog was answered. This catches approvals of long-running commands, where the next
    /// hook event (`PostToolUse`) can be minutes away.
    private static func registryMovedOn(since: Date, input: AgentStatusInput) -> Bool {
        guard let updatedAt = input.registryUpdatedAt else { return false }
        return updatedAt > since.addingTimeInterval(registryLag)
    }

    private static func isBusy(_ input: AgentStatusInput) -> Bool {
        switch input.registryStatus {
        case "busy": return true
        case "idle": return false
        default: break
        }
        switch input.hookPhase {
        case .working: return true
        case .stopped: return false
        case .awaitingApproval, .awaitingInput, .none: break
        }
        if input.lastStopReason == "end_turn" { return false }
        guard let lastActivity = input.lastActivity else { return false }
        return input.now.timeIntervalSince(lastActivity) < recentActivityWindow
    }

    private static func finishedAt(_ input: AgentStatusInput) -> Date? {
        if case .stopped(let since) = input.hookPhase { return since }
        return input.lastActivity ?? input.statusUpdatedAt
    }
}
