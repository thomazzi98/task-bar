import AppKit
import Observation
import SwiftUI
import TaskBarCore

/// The composition root: builds every model and service, wires them together, and owns the
/// app-level behaviour (keyboard shortcuts, Escape handling, lifecycle).
@MainActor
final class AppEnvironment {
    let paths: AppPaths
    let settings: SettingsStore
    let appState = AppState()
    let tasks: TasksViewModel
    let notes: NotesViewModel
    let links: LinksViewModel
    let agents: AgentsViewModel
    let usage: UsageViewModel
    let agenda: AgendaViewModel
    let system = SystemViewModel()
    let ports = PortsViewModel()
    let clipboard: ClipboardViewModel
    let peripherals = PeripheralsViewModel()
    let assistant: TextAssistant
    let git: GitViewModel

    private let defaults: UserDefaults
    private let notifier = Notifier()
    private let hotKeys = HotKeyManager()
    private let clipboardMonitor: ClipboardMonitor
    private var statusItem: StatusItemController?

    init(paths: AppPaths = .live(), defaults: UserDefaults = .standard) {
        self.paths = paths
        self.defaults = defaults
        settings = SettingsStore(defaults: defaults)
        tasks = TasksViewModel(store: JSONFileStore(url: paths.tasksFile))
        notes = NotesViewModel(store: JSONFileStore(url: paths.notesFile))
        links = LinksViewModel(store: JSONFileStore(url: paths.linksFile))
        agents = AgentsViewModel(paths: paths)
        usage = UsageViewModel(paths: paths)
        agenda = AgendaViewModel(service: CalendarService(), notifier: notifier, settings: settings)
        let clipboardModel = ClipboardViewModel(store: JSONFileStore(url: paths.clipboardFile))
        clipboard = clipboardModel
        clipboardMonitor = ClipboardMonitor { clipboardModel.capture($0) }
        assistant = TextAssistant(settings: settings, appState: appState)
        git = GitViewModel(paths: paths, agents: agents)
    }

    /// The popover's content with every dependency injected.
    func rootView() -> some View {
        RootView()
            .environment(appState)
            .environment(settings)
            .environment(tasks)
            .environment(notes)
            .environment(links)
            .environment(agents)
            .environment(usage)
            .environment(agenda)
            .environment(system)
            .environment(ports)
            .environment(clipboard)
            .environment(peripherals)
            .environment(assistant)
            .environment(git)
            .environment(\.appActions, actions)
            // View-level preferences (`@AppStorage`) share the injected store too.
            .defaultAppStorage(defaults)
    }

    // MARK: Lifecycle

    func start() {
        appState.selectedTab = settings.lastTab

        let controller = StatusItemController(appState: appState, settings: settings, content: rootView())
        controller.onEscape = { [weak self] in self?.handleEscape() ?? false }
        controller.onCommandKey = { [weak self] key in self?.handleCommandKey(key) ?? false }
        controller.onVisibilityChange = { [weak self] isVisible in self?.panelVisibilityChanged(isVisible) }
        controller.contextMenuProvider = { [weak self] in self?.makeContextMenu() ?? NSMenu() }
        statusItem = controller

        agents.onBadgeChange = { [weak controller] badge in controller?.updateBadge(badge) }
        agents.onAttentionNeeded = { [weak self] session in self?.notifyAttention(for: session) }
        agents.start()
        agenda.start()

        bindShortcuts()
        observeShortcutSettings()
        updateBackgroundActivity()
        observeActivityInputs()
        updateClipboardMonitoring()
        observeClipboardSetting()
        Log.app.info("TaskBar \(AppBundle.version, privacy: .public) started, data at \(self.paths.supportDirectory.path, privacy: .public)")
    }

    func shutdown() {
        assistant.stopDictation()
        agents.stop()
        clipboardMonitor.stop()
        tasks.flush()
        notes.flush()
        clipboard.flush()
        links.flush()
    }

    // MARK: Clipboard history

    /// Runs the pasteboard monitor only while clipboard history is enabled.
    private func updateClipboardMonitoring() {
        if settings.keepsClipboardHistory {
            clipboardMonitor.start()
        } else {
            clipboardMonitor.stop()
        }
    }

    private func observeClipboardSetting() {
        withObservationTracking {
            _ = settings.keepsClipboardHistory
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateClipboardMonitoring()
                self?.observeClipboardSetting()
            }
        }
    }

    private func panelVisibilityChanged(_ isVisible: Bool) {
        Log.app.debug("popover \(isVisible ? "shown" : "hidden", privacy: .public)")
        updateBackgroundActivity()
        guard !isVisible else { return }
        // Closing is the natural moment to make sure nothing is left unsaved or recording.
        assistant.stopDictation()
        tasks.flush()
        notes.flush()
        links.flush()
    }

    // MARK: Background activity

    /// Runs only the sampling the visible screen needs and, with the popover closed, none at
    /// all. This is decided here rather than in SwiftUI modifiers because a hidden window
    /// stops updating its views, and the work must stop exactly then.
    private func updateBackgroundActivity() {
        let isVisible = appState.isPanelVisible
        let tab = settings.visibleTab(for: appState.selectedTab)
        let showsTab = isVisible && !appState.isShowingSettings && !appState.isSearching

        system.showsStoppedContainers = settings.showsStoppedContainers
        system.setPanelVisible(isVisible)
        system.setDetailVisible(showsTab && tab == .system)
        ports.setVisible(showsTab && tab == .system)
        peripherals.setVisible(showsTab && tab == .system)
        agents.setVisible(showsTab && tab == .agents)
        git.setVisible(showsTab && tab == .git)
        usage.setVisible(showsTab && tab == .agents && usage.section == .usage)
        agenda.setVisible(isVisible && settings.isEnabled(.calendar))
    }

    private func observeActivityInputs() {
        withObservationTracking {
            _ = appState.isPanelVisible
            _ = appState.selectedTab
            _ = appState.isShowingSettings
            _ = appState.isSearching
            _ = usage.section
            _ = settings.disabledTabs
            _ = settings.showsStoppedContainers
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateBackgroundActivity()
                self?.observeActivityInputs()
            }
        }
    }

    // MARK: Actions exposed to views

    private var actions: AppActions {
        AppActions(
            quit: { NSApp.terminate(nil) },
            revealDataFolder: { [paths] in Opener.revealInFinder(paths.supportDirectory) },
            requestNotificationPermission: { [weak self] in
                guard let self else { return }
                Task { await self.appState.holdingOpen { await self.notifier.requestAuthorization() } }
            }
        )
    }

    private func notifyAttention(for session: AgentSession) {
        guard settings.notifiesOnAttention else { return }
        // No banner when the user is already looking at the agents list.
        if appState.isPanelVisible, appState.selectedTab == .agents { return }
        notifier.post(
            identifier: "taskbar.agent.\(session.id)",
            title: "\(session.projectName) is waiting for you",
            body: session.statusDetail ?? session.status.label
        )
    }

    // MARK: Global shortcuts

    private func bindShortcuts() {
        hotKeys.bind(.togglePanel, to: settings.toggleShortcut) { [weak self] in
            self?.statusItem?.toggle()
        }
        hotKeys.bind(.voiceCapture, to: settings.voiceShortcut) { [weak self] in
            self?.startVoiceNote()
        }
    }

    /// Re-registers the shortcuts whenever the user records new ones.
    private func observeShortcutSettings() {
        withObservationTracking {
            _ = settings.toggleShortcut
            _ = settings.voiceShortcut
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.bindShortcuts()
                self?.observeShortcutSettings()
            }
        }
    }

    /// Opens a fresh note and starts dictating into it right away.
    private func startVoiceNote() {
        statusItem?.show()
        appState.select(.notes)
        let noteID = notes.createNote(kind: .note)
        let notes = notes
        Task { [assistant] in
            // Let the editor appear before the transcript starts flowing into it.
            try? await Task.sleep(for: .milliseconds(250))
            assistant.toggleDictation(
                targetID: "note-\(noteID.uuidString)",
                text: "",
                insertionOffset: nil
            ) { notes.setBody(noteID, to: $0) }
        }
    }

    // MARK: Keyboard handling inside the popover

    /// Escape steps back one level at a time and finally closes the popover.
    private func handleEscape() -> Bool {
        if assistant.dictationState != .idle {
            assistant.stopDictation()
        } else if assistant.proposal != nil {
            assistant.discardProposal()
        } else if appState.isSearching {
            appState.endSearch()
        } else if appState.isShowingSettings {
            appState.isShowingSettings = false
        } else if !stepBackInCurrentTab() {
            statusItem?.hide()
        }
        return true
    }

    private func stepBackInCurrentTab() -> Bool {
        switch appState.selectedTab {
        case .tasks:
            return tasks.goBack()
        case .notes:
            return notes.closeEditor()
        case .agents:
            guard agents.selectedSessionID != nil else { return false }
            agents.select(nil)
            return true
        case .links:
            return links.closeFolder()
        case .git:
            return git.closeDetail()
        case .clipboard, .calendar, .system:
            return false
        }
    }

    private func handleCommandKey(_ key: String) -> Bool {
        switch key {
        case "f":
            appState.beginSearch()
        case "n":
            createNewItem()
        case "p":
            appState.isPinned.toggle()
        case ",":
            appState.isSearching = false
            appState.isShowingSettings.toggle()
        case "w":
            statusItem?.hide()
        default:
            // ⌘1…⌘9 jump to the nth visible tab.
            guard let number = Int(key), number >= 1, number <= settings.enabledTabs.count else { return false }
            let tab = settings.enabledTabs[number - 1]
            appState.select(tab)
            settings.lastTab = tab
        }
        return true
    }

    private func createNewItem() {
        if appState.selectedTab == .notes, !appState.isShowingSettings, !appState.isSearching {
            notes.createNote()
        } else if appState.selectedTab == .links, !appState.isShowingSettings, !appState.isSearching {
            // Inside a folder, ⌘N focuses the paste box; on the home grid it makes a new folder.
            if links.openFolderID == nil { links.createFolder() }
        } else {
            appState.select(.tasks)
        }
        appState.requestPrimaryFocus()
    }

    // MARK: URL scheme

    /// Carries out a `taskbar://` command from Shortcuts, Raycast, a script, and so on.
    func handle(_ command: URLCommand) {
        Log.app.info("URL command: \(command.name, privacy: .public)")
        switch command {
        case .open:
            statusItem?.show()
        case .toggle:
            statusItem?.toggle()
        case .close:
            statusItem?.hide()
        case .showTab(let name):
            guard let tab = AppTab(rawValue: name), settings.isEnabled(tab) else { return }
            appState.select(tab)
            statusItem?.show()
        case .addTask(let title):
            // Capturing is silent: the popover is not forced open over the user's work.
            tasks.add(title: title, under: nil)
            tasks.flush()
        case .addNote(let text, let isPrompt):
            notes.insert(Note(body: text, kind: isPrompt ? .prompt : .note))
            notes.flush()
        }
    }

    // MARK: Menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Open TaskBar") { [weak self] in
            self?.statusItem?.show()
        })
        menu.addItem(ClosureMenuItem(title: "Settings…") { [weak self] in
            guard let self else { return }
            self.appState.isShowingSettings = true
            self.statusItem?.show()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit TaskBar") { NSApp.terminate(nil) })
        return menu
    }
}

/// A menu item that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
