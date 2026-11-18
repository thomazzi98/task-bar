import AppKit
import SwiftUI
import TaskBarCore

/// The Agents tab: every Claude Code session running on this Mac and what it needs.
struct AgentsView: View {
    @Environment(AgentsViewModel.self) private var agents
    @AppStorage("agents.hooksHintDismissed") private var isHooksHintDismissed = false

    var body: some View {
        Group {
            if let session = agents.selectedSession {
                AgentDetailView(session: session)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: agents.selectedSessionID)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if showsHooksHint {
                hooksHint
                    .padding(.horizontal, Design.gutter)
                    .padding(.top, 10)
            }
            if agents.sessions.isEmpty {
                EmptyStateView(
                    symbol: "sparkles",
                    title: agents.claudeCodeDetected ? "No agents running" : "Claude Code not found",
                    message: agents.claudeCodeDetected
                        ? "Start a Claude Code session and it will show up here."
                        : "Install Claude Code to monitor its sessions from the menu bar."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(agents.sessions) { session in
                            AgentRow(session: session, memoryBytes: agents.memoryByPID[session.pid])
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var showsHooksHint: Bool {
        agents.claudeCodeDetected && !agents.hooksInstalled && !isHooksHintDismissed
    }

    private var hooksHint: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Get instant alerts").font(.system(size: 11.5, weight: .semibold))
                Text("Install the Claude Code hooks to know the moment an agent needs approval.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            PillButton(title: "Install", isProminent: true) { agents.installHooks() }
            Button {
                isHooksHintDismissed = true
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.09)))
    }
}

/// A coloured dot that pulses while the agent is working.
struct AgentStatusDot: View {
    let status: AgentStatus

    var body: some View {
        Group {
            if status.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Design.color(for: status))
            } else if status == .working {
                PulsingDot(color: NSColor(Design.color(for: status)))
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(Design.color(for: status))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14)
        .accessibilityLabel(status.label)
    }
}

/// A dot whose pulse is a Core Animation layer animation. Those run in the window server,
/// so the app itself does no per-frame work, unlike a SwiftUI animation that repeats forever.
private struct PulsingDot: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let dot = CALayer()
        dot.name = "dot"
        view.layer?.addSublayer(dot)

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "pulse")
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let dot = view.layer?.sublayers?.first(where: { $0.name == "dot" }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = view.bounds
        dot.cornerRadius = min(view.bounds.width, view.bounds.height) / 2
        dot.backgroundColor = color.cgColor
        CATransaction.commit()
    }
}

private struct AgentRow: View {
    let session: AgentSession
    let memoryBytes: UInt64?

    @Environment(AgentsViewModel.self) private var agents

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentStatusDot(status: session.status)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.status.label)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Design.color(for: session.status))
                }
                Text(session.displayTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = session.statusDetail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: session.status.needsAttention ? .default : .monospaced))
                        .foregroundStyle(session.status.needsAttention ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .lineLimit(2)
                }
                footnote
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { agents.select(session.id) }
        .hoverHighlight()
        .contextMenu {
            Button("Focus Window") { agents.focusWindow(of: session) }
            Button("Copy Resume Command") { Opener.copyToPasteboard(session.resumeCommand) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var footnote: some View {
        HStack(spacing: 8) {
            if let lastActivity = session.lastActivity {
                Label {
                    Text(lastActivity, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                } icon: {
                    Image(systemName: "clock")
                }
            }
            if let branch = session.gitBranch, branch != "HEAD" {
                Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
            }
            if let memoryBytes, memoryBytes > 0 {
                Label(Formatting.bytes(memoryBytes), systemImage: "memorychip")
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.top, 1)
    }
}

/// An icon and text set tighter than the default label.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2.5) {
            configuration.icon.font(.system(size: 8.5))
            configuration.title
        }
    }
}

/// One session in depth: what it is waiting for, the recent conversation, and quick actions.
private struct AgentDetailView: View {
    let session: AgentSession

    @Environment(AgentsViewModel.self) private var agents
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            BackBar(title: "Agents", onBack: { agents.select(nil) }) {
                PillButton(title: "Copy resume", symbol: "doc.on.doc", tint: .secondary) {
                    Opener.copyToPasteboard(session.resumeCommand)
                    appState.showToast("Resume command copied")
                }
                PillButton(title: "Focus window", symbol: "macwindow", isProminent: true, action: focus)
            }
            header
            Divider().opacity(0.5)
            conversation
        }
    }

    private func focus() {
        if case .focused(let appName) = agents.focusWindow(of: session) {
            appState.showToast("Switched to \(appName)")
        } else {
            appState.showToast("Could not find the session's window")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                AgentStatusDot(status: session.status)
                Text(session.projectName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Chip(text: session.status.label, tint: Design.color(for: session.status))
            }
            Text(session.displayTitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if session.status.needsAttention {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: session.status == .needsApproval ? "hand.raised.fill" : "questionmark.bubble.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(session.statusDetail ?? (session.status == .needsApproval
                        ? "Waiting for you to approve a tool call."
                        : "Waiting for your answer."))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.11)))
            }

            HStack(spacing: 9) {
                Label(abbreviatedPath, systemImage: "folder").lineLimit(1).truncationMode(.head)
                if let branch = session.gitBranch, branch != "HEAD" {
                    Label(branch, systemImage: "arrow.triangle.branch").lineLimit(1)
                }
                if let model = session.model {
                    Label(model, systemImage: "cpu").lineLimit(1)
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Design.gutter)
        .padding(.bottom, 9)
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return session.cwd.hasPrefix(home) ? "~" + session.cwd.dropFirst(home.count) : session.cwd
    }

    private var conversation: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if session.entries.isEmpty {
                        Text("No conversation yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    ForEach(session.entries) { entry in
                        TranscriptEntryView(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, Design.gutter)
                .padding(.vertical, 10)
            }
            .onAppear { scrollToEnd(scroller, animated: false) }
            .onChange(of: session.entries.last?.id) { scrollToEnd(scroller, animated: true) }
        }
    }

    private func scrollToEnd(_ scroller: ScrollViewProxy, animated: Bool) {
        guard let last = session.entries.last else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(last.id, anchor: .bottom) }
        } else {
            scroller.scrollTo(last.id, anchor: .bottom)
        }
    }
}

private struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userPrompt:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .font(.system(size: 12))
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.16)))
            }
        case .assistantText:
            Text(InlineMarkdown.attributed(entry.text))
                .font(.system(size: 12))
                .lineSpacing(1.5)
                .lineLimit(16)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolUse(let name):
            HStack(spacing: 5) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: 8.5))
                Text(name).fontWeight(.medium)
                if !entry.text.isEmpty {
                    Text(entry.text).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
        }
    }
}
