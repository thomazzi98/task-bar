import Foundation
import Observation
import TaskBarCore

/// One message of the Ask transcript.
struct AskMessage: Identifiable {
    enum Role { case user, assistant, error }

    let id = UUID()
    let role: Role
    var text: String
    var actions: [AskAction] = []
}

/// An action Claude proposed, with its result once the user has run it.
struct AskAction: Identifiable {
    let id = UUID()
    let proposal: ProposedAction
    var outcome: String?
}

/// The Ask tab: questions about this Mac, answered from a live snapshot.
///
/// The conversation lives in memory only. "New chat" and quitting the app drop it. Nothing runs
/// until the user sends a question or confirms an action, and no question is sent on its own.
@MainActor
@Observable
final class AssistantViewModel {
    static let suggestions = ["Why is my CPU high?", "What's using my memory?", "Is anything stuck or misbehaving?"]

    private(set) var messages: [AskMessage] = []
    private(set) var isThinking = false
    /// The action whose confirmation bar is showing, if any.
    private(set) var armedActionID: UUID?

    @ObservationIgnored private let collector = MachineSnapshotCollector()
    @ObservationIgnored private let docker = DockerClient()
    @ObservationIgnored private var questionTask: Task<Void, Never>?

    // MARK: Conversation

    func send(_ question: String) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }

        let history = messages.compactMap { message -> AssistantTurn? in
            switch message.role {
            case .user: AssistantTurn(role: .user, text: message.text)
            case .assistant: AssistantTurn(role: .assistant, text: message.text)
            case .error: nil
            }
        }
        messages.append(AskMessage(role: .user, text: text))
        isThinking = true
        questionTask = Task { [weak self] in
            guard let self else { return }
            let reply = await self.answer(to: text, history: history)
            guard !Task.isCancelled else { return }
            self.messages.append(reply)
            self.isThinking = false
        }
    }

    /// Starts a fresh conversation. Anything still being answered is discarded.
    func clear() {
        questionTask?.cancel()
        questionTask = nil
        messages = []
        isThinking = false
        armedActionID = nil
    }

    private func answer(to question: String, history: [AssistantTurn]) async -> AskMessage {
        guard let executable = ClaudeCLILocator.locate() else {
            return AskMessage(role: .error, text: "Claude Code is not installed on this Mac. Ask needs it. Everything else works without it.")
        }
        let report = MachineReport.text(for: await collector.collect())
        let assistant = ClaudeAssistant(executable: executable, projectsDirectory: AppPaths.live().claudeProjectsDirectory)
        do {
            let raw = try await assistant.answer(question: question, report: report, history: history)
            let parsed = AssistantReply.parse(raw)
            guard !parsed.text.isEmpty || !parsed.actions.isEmpty else {
                return AskMessage(role: .error, text: "Claude returned an empty answer.")
            }
            return AskMessage(
                role: .assistant,
                text: parsed.text,
                actions: parsed.actions.map { AskAction(proposal: $0) }
            )
        } catch {
            return AskMessage(role: .error, text: error.localizedDescription)
        }
    }

    // MARK: Actions

    /// Shows the confirmation bar for an action. Nothing runs until the user confirms.
    func arm(_ action: AskAction) {
        armedActionID = action.id
    }

    func disarm() {
        armedActionID = nil
    }

    /// Runs an action the user has confirmed, and records its result under the button.
    func run(_ action: AskAction) {
        guard let location = location(of: action.id), messages[location.message].actions[location.action].outcome == nil else {
            return
        }
        armedActionID = nil
        let docker = self.docker
        Task { [weak self] in
            let outcome = await AskActionRunner.perform(action.proposal, docker: docker)
            self?.setOutcome(outcome, for: action.id)
        }
    }

    private func setOutcome(_ outcome: String, for actionID: UUID) {
        guard let location = location(of: actionID) else { return }
        messages[location.message].actions[location.action].outcome = outcome
    }

    private func location(of actionID: UUID) -> (message: Int, action: Int)? {
        for (messageIndex, message) in messages.enumerated() {
            if let actionIndex = message.actions.firstIndex(where: { $0.id == actionID }) {
                return (messageIndex, actionIndex)
            }
        }
        return nil
    }

    /// Replaces the transcript with sample content. Used only by snapshot rendering.
    func applyPreview(messages: [AskMessage]) {
        self.messages = messages
        isThinking = false
        armedActionID = nil
    }
}
