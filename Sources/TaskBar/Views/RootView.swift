import SwiftUI
import TaskBarCore

/// App-level actions that views trigger without knowing who performs them.
struct AppActions {
    var quit: @MainActor () -> Void = {}
    var revealDataFolder: @MainActor () -> Void = {}
    var requestNotificationPermission: @MainActor () -> Void = {}
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue = AppActions()
}

extension EnvironmentValues {
    var appActions: AppActions {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}

/// The popover's layout: tab bar, the selected screen, and a status footer.
struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(AgendaViewModel.self) private var agenda

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(activeTab: activeTab)
            if let event = agenda.nextEvent, settings.isEnabled(.calendar), !appState.isShowingSettings {
                NextEventStrip(event: event, now: agenda.clock)
            }
            Divider().opacity(0.6)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.6)
            FooterBar()
        }
        .frame(width: Design.panelWidth)
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.18), value: appState.toast)
        .overlay(
            RoundedRectangle(cornerRadius: PopoverPanel.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }

    private var activeTab: AppTab {
        settings.visibleTab(for: appState.selectedTab)
    }

    @ViewBuilder
    private var content: some View {
        if appState.isShowingSettings {
            SettingsView()
        } else if appState.isSearching {
            SearchResultsView()
        } else {
            switch activeTab {
            case .tasks: TasksView()
            case .notes: NotesView()
            case .agents: AgentsView()
            case .calendar: AgendaView()
            case .system: SystemView()
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = appState.toast {
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .padding(.bottom, 36)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(message)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    let activeTab: AppTab

    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(AgentsViewModel.self) private var agents
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var appState = appState
        HStack(spacing: 3) {
            if appState.isSearching {
                searchField(text: $appState.searchQuery)
            } else {
                ForEach(settings.enabledTabs) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: tab == activeTab && !appState.isShowingSettings,
                        badgeCount: tab == .agents ? agents.attentionCount : 0
                    ) {
                        appState.select(tab)
                        settings.lastTab = tab
                    }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "magnifyingglass", help: "Search tasks and notes (⌘F)") { appState.beginSearch() }
            }
            IconButton(
                symbol: appState.isPinned ? "pin.fill" : "pin",
                help: appState.isPinned ? "Unpin (⌘P)" : "Keep open (⌘P)",
                isActive: appState.isPinned
            ) {
                appState.isPinned.toggle()
            }
            IconButton(symbol: "gearshape", help: "Settings (⌘,)", isActive: appState.isShowingSettings) {
                appState.isSearching = false
                appState.isShowingSettings.toggle()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .animation(.snappy(duration: 0.2), value: activeTab)
        .animation(.easeOut(duration: 0.15), value: appState.isSearching)
    }

    private func searchField(text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5)).foregroundStyle(.secondary)
            TextField("Search tasks and notes", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
            Button {
                appState.endSearch()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .onAppear { isSearchFocused = true }
        .onChange(of: appState.focusRequest) { isSearchFocused = true }
    }
}

private struct TabButton: View {
    let tab: AppTab
    let isSelected: Bool
    let badgeCount: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .overlay(alignment: .topTrailing) {
                        if badgeCount > 0 {
                            Circle().fill(Color.orange).frame(width: 6.5, height: 6.5).offset(x: 4, y: -3)
                        }
                    }
                if isSelected {
                    Text(tab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .padding(.horizontal, isSelected ? 10 : 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(isHovered ? 0.07 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(badgeCount > 0 ? "\(tab.title) — \(badgeCount) waiting for you" : tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    @Environment(SystemViewModel.self) private var system
    @Environment(AgentsViewModel.self) private var agents

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if settings.isEnabled(.system) { appState.select(.system) }
            } label: {
                HStack(spacing: 9) {
                    Label(cpuText, systemImage: "cpu")
                    Label(memoryText, systemImage: "memorychip")
                }
                .labelStyle(CompactLabelStyle())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("CPU and memory in use — open System")

            Spacer(minLength: 4)

            if settings.isEnabled(.agents), !agents.sessions.isEmpty {
                Button {
                    appState.select(.agents)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(agentSummaryColor).frame(width: 6, height: 6)
                        Text(agentSummary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Agents")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, Design.gutter)
        .frame(height: 26)
    }

    private var cpuText: String {
        system.snapshot?.cpu.map { Formatting.percent($0.overall) } ?? "—"
    }

    private var memoryText: String {
        guard let memory = system.snapshot?.memory else { return "—" }
        return "\(Formatting.bytes(memory.usedBytes)) / \(Formatting.bytes(memory.totalBytes))"
    }

    private var agentSummary: String {
        let waiting = agents.attentionCount
        let total = agents.sessions.count
        if waiting > 0 { return "\(waiting) agent\(waiting == 1 ? "" : "s") waiting for you" }
        let working = agents.sessions.filter { $0.status == .working }.count
        if working > 0 { return "\(working) of \(total) agent\(total == 1 ? "" : "s") working" }
        return "\(total) agent\(total == 1 ? "" : "s") idle"
    }

    private var agentSummaryColor: Color {
        if agents.attentionCount > 0 { return .orange }
        return agents.sessions.contains { $0.status == .working } ? .blue : .secondary.opacity(0.6)
    }
}

// MARK: - Search

/// Results across every task (at any depth) and every note.
struct SearchResultsView: View {
    @Environment(AppState.self) private var appState
    @Environment(TasksViewModel.self) private var tasks
    @Environment(NotesViewModel.self) private var notes

    var body: some View {
        let query = appState.searchQuery.trimmingCharacters(in: .whitespaces)
        let results = Search.run(query: query, tasks: tasks.tasks, notes: notes.notes)

        if query.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "Search", message: "Find any task, subtask or note by its title or text.")
        } else if results.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: "No results", message: "Nothing matches “\(query)”.")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results) { result in
                        row(result)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
            }
        }
    }

    private func row(_ result: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol(for: result))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.system(size: 13))
                    .strikethrough(result.isDone)
                    .foregroundStyle(result.isDone ? .secondary : .primary)
                    .lineLimit(1)
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { open(result) }
        .hoverHighlight()
    }

    private func symbol(for result: SearchResult) -> String {
        switch result.target {
        case .task: result.isDone ? "checkmark.circle" : "circle"
        case .note: "note.text"
        }
    }

    private func open(_ result: SearchResult) {
        switch result.target {
        case .task(let path):
            tasks.navigate(toPath: path)
            appState.select(.tasks)
        case .note(let id):
            notes.open(id)
            appState.select(.notes)
        }
        appState.endSearch()
    }
}
