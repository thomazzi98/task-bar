import SwiftUI
import TaskBarCore

/// The Ask tab: questions about this Mac, answered from a live snapshot. Claude may propose
/// actions, which appear as buttons that run only after a confirmation.
struct AskView: View {
    @Environment(AssistantViewModel.self) private var assistant

    private static let bottomID = "ask.bottom"

    var body: some View {
        VStack(spacing: 0) {
            if assistant.messages.isEmpty {
                emptyState
            } else {
                transcript
            }
            inputBar
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text("Ask about this Mac")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Answers are based on a live snapshot of this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 6) {
                ForEach(AssistantViewModel.suggestions, id: \.self) { suggestion in
                    SuggestionChip(text: suggestion) { assistant.send(suggestion) }
                }
            }
            .frame(width: 300)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Transcript

    private var transcript: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 4)
                PillButton(title: "New chat", symbol: "square.and.pencil", tint: .secondary) {
                    assistant.clear()
                }
            }
            .padding(.horizontal, Design.gutter)
            .padding(.top, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(assistant.messages) { message in
                            messageView(message)
                        }
                        if assistant.isThinking {
                            thinkingRow
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(.horizontal, Design.gutter)
                    .padding(.vertical, 8)
                }
                .onChange(of: assistant.messages.count) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
                .onChange(of: assistant.isThinking) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func messageView(_ message: AskMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    MarkdownPreview(text: message.text, scrolls: false)
                }
                ForEach(message.actions) { action in
                    actionView(action)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            NoticeBanner(text: message.text)
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking…")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: Proposed actions

    @ViewBuilder
    private func actionView(_ action: AskAction) -> some View {
        if assistant.armedActionID == action.id {
            InlineConfirmBar(
                message: "\(action.proposal.title)?",
                confirmTitle: Self.confirmTitle(for: action.proposal),
                onConfirm: { assistant.run(action) },
                onCancel: { assistant.disarm() }
            )
        } else if let outcome = action.outcome {
            Text(outcome)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            PillButton(
                title: action.proposal.title,
                symbol: Self.symbol(for: action.proposal),
                tint: Self.tint(for: action.proposal)
            ) {
                assistant.arm(action)
            }
        }
    }

    private static func confirmTitle(for action: ProposedAction) -> String {
        switch action {
        case .quit: "Quit"
        case .forceQuit: "Force quit"
        case .stopContainer: "Stop"
        case .openURL: "Open"
        }
    }

    private static func symbol(for action: ProposedAction) -> String {
        switch action {
        case .quit, .forceQuit: "xmark.circle"
        case .stopContainer: "stop.circle"
        case .openURL: "safari"
        }
    }

    private static func tint(for action: ProposedAction) -> Color {
        switch action {
        case .quit: .orange
        case .forceQuit, .stopContainer: .red
        case .openURL: .accentColor
        }
    }

    // MARK: Input

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuickAddField(placeholder: "Ask about this Mac", symbol: "bubble.left", isPrimary: true) { question in
                assistant.send(question)
            }
            .disabled(assistant.isThinking)
            Text("Sends a summary of this Mac's state (process names, usage, ports) to Claude through your Claude Code login.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 8)
    }
}

/// A suggested first question, shown on the empty Ask screen.
private struct SuggestionChip: View {
    let text: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.09 : 0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
