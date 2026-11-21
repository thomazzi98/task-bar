import Foundation
import Testing
@testable import TaskBarCore

@Suite("Assistant prompt")
struct AssistantPromptTests {
    @Test func sendsOnlyTheLastSixMessagesBeforeTheQuestion() {
        let history = (1...9).map { AssistantTurn(role: $0 % 2 == 1 ? .user : .assistant, text: "message \($0)") }
        let message = AssistantPrompt.userMessage(question: "Why?", report: "REPORT", history: history)

        #expect(!message.contains("message 3\n"))
        #expect(message.contains("Assistant: message 4\n"))
        #expect(message.contains("User: message 5\n"))
        #expect(message.contains("User: message 9\n"))
        #expect(message.contains("<question>\nWhy?\n</question>"))
    }

    @Test func wrapsTheSnapshotAsData() {
        let message = AssistantPrompt.userMessage(question: "Why?", report: "- yes, pid 1", history: [])
        #expect(message.hasPrefix("<machine_snapshot>\n- yes, pid 1\n</machine_snapshot>"))
        #expect(!message.contains("<conversation>"))
    }

    @Test func shortensLongEarlierMessages() {
        let long = String(repeating: "a", count: 5_000)
        let message = AssistantPrompt.userMessage(
            question: "Next?", report: "R", history: [AssistantTurn(role: .assistant, text: long)]
        )
        #expect(message.contains(String(repeating: "a", count: 1_500) + "..."))
        #expect(!message.contains(String(repeating: "a", count: 1_501)))
    }

    @Test func systemPromptNamesTheFourKindsAndTheConfirmationRule() {
        let prompt = AssistantPrompt.systemPrompt
        for kind in ["quit pid=", "force-quit pid=", "stop-container id=", "open-url url="] {
            #expect(prompt.contains(kind))
        }
        #expect(prompt.contains("clicks it and confirms"))
        #expect(prompt.contains("never for a system process"))
    }

    @Test func assistantRunsIsolatedWithTheSonnetModel() {
        let arguments = ClaudeCLI.arguments(model: ClaudeAssistant.model, systemPrompt: "S", sessionID: "id")
        #expect(ClaudeAssistant.model == "sonnet")
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("--tools"))
        #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
    }
}
