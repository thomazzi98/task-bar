import Foundation
import Observation
import TaskBarCore

/// Live view of the Claude Code sessions running on this Mac.
///
/// Refreshes are event-driven: a file-system watcher on the session registry and on the hook
/// spool triggers them, so nothing is polled while the popover is closed. A light timer runs
/// only while the Agents tab is visible, to keep the conversation preview current.
@MainActor
@Observable
final class AgentsViewModel {
    private(set) var sessions: [AgentSession] = []
    /// Memory footprint of each session's process, keyed by PID.
    private(set) var memoryByPID: [Int32: UInt64] = [:]
    private(set) var selectedSessionID: String?
    private(set) var hooksInstalled = false
    private(set) var hookMessage: String?
    /// Whether Claude Code's data directory exists at all.
    private(set) var claudeCodeDetected = false

    /// Called whenever the menu bar badge should change.
    @ObservationIgnored var onBadgeChange: ((BadgeState) -> Void)?
    /// Called when a session starts needing the user.
    @ObservationIgnored var onAttentionNeeded: ((AgentSession) -> Void)?

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private let scanner: AgentScanner
    @ObservationIgnored private let spool: HookEventSpool
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var visibleTask: Task<Void, Never>?
    @ObservationIgnored private var safetyTask: Task<Void, Never>?
    @ObservationIgnored private var badge: BadgeState = .none
    @ObservationIgnored private var attentionIDs: Set<String> = []
    @ObservationIgnored private var isListVisible = false

    init(paths: AppPaths) {
        self.paths = paths
        scanner = AgentScanner(paths: paths)
        spool = HookEventSpool(directory: paths.hookEventsDirectory)
    }

    // MARK: Lifecycle

    func start() {
        try? spool.open(processID: ProcessInfo.processInfo.processIdentifier)
        hooksInstalled = HookInstaller.isInstalled(paths: paths)
        claudeCodeDetected = FileManager.default.fileExists(atPath: paths.claudeDirectory.path)

        // Prefer watching just the registry; fall back to the whole Claude directory when the
        // registry folder does not exist yet (it is created by the first session).
        let registry = paths.claudeSessionsDirectory
        let watched = FileManager.default.fileExists(atPath: registry.path) ? registry : paths.claudeDirectory
        for directory in [watched, paths.hookEventsDirectory] {
            let watcher = DirectoryWatcher(url: directory) { [weak self] in
                Task { @MainActor in self?.scheduleRefresh() }
            }
            if let watcher { watchers.append(watcher) }
        }

        // A crashed session leaves its registry file behind without any file-system event.
        // One cheap pass a minute is enough to notice and clear a stale badge.
        safetyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refresh()
            }
        }
        scheduleRefresh()
    }

    func stop() {
        watchers.forEach { $0.stop() }
        watchers = []
        refreshTask?.cancel()
        visibleTask?.cancel()
        safetyTask?.cancel()
        spool.close()
    }

    /// Starts or stops the conversation refresh that runs while the list is on screen.
    func setVisible(_ visible: Bool) {
        guard visible != isListVisible else { return }
        isListVisible = visible
        visibleTask?.cancel()
        visibleTask = nil
        guard visible else {
            // The user has now seen whatever finished; stop highlighting it.
            acknowledgeFinished()
            return
        }

        visibleTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Refreshing

    /// Coalesces bursts of file-system events into one refresh.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        let events = await scanner.ingestHookEvents()
        if !events.isEmpty {
            Log.agents.info("ingested \(events.count, privacy: .public) hook event(s)")
        }
        let scanned = await scanner.scan()
        apply(scanned)
    }

    /// Replaces the session list. Exposed for previews and snapshot rendering.
    func apply(_ scanned: [AgentSession]) {
        if scanned != sessions {
            sessions = scanned
        }
        if let selectedSessionID, !scanned.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }

        var memory: [Int32: UInt64] = [:]
        for session in scanned {
            memory[session.pid] = ProcessInspector.resourceUsage(of: session.pid)?.memoryBytes
        }
        if memory != memoryByPID { memoryByPID = memory }

        notifyAboutNewAttention(in: scanned)
        updateBadge()
    }

    // MARK: Selection and actions

    var selectedSession: AgentSession? {
        selectedSessionID.flatMap { id in sessions.first { $0.id == id } }
    }

    var attentionCount: Int {
        sessions.reduce(0) { $0 + ($1.status.needsAttention ? 1 : 0) }
    }

    func select(_ sessionID: String?) {
        selectedSessionID = sessionID
    }

    @discardableResult
    func focusWindow(of session: AgentSession) -> WindowFocuser.Outcome {
        WindowFocuser.focus(session, paths: paths)
    }

    func installHooks() {
        do {
            let backup = try HookInstaller.install(paths: paths)
            hooksInstalled = true
            hookMessage = backup.map { "Hooks installed. Previous settings saved as \($0.lastPathComponent)." }
                ?? "Hooks installed."
            Log.agents.info("hooks installed")
        } catch {
            hookMessage = error.localizedDescription
            Log.agents.error("installing hooks failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(paths: paths)
            hooksInstalled = false
            hookMessage = "Hooks removed."
        } catch {
            hookMessage = error.localizedDescription
        }
    }

    // MARK: Private

    private func acknowledgeFinished() {
        let finished = sessions.filter { $0.status == .finished }.map(\.id)
        guard !finished.isEmpty else { return }
        Task { [weak self, scanner] in
            await scanner.acknowledge(sessionIDs: finished)
            await self?.refresh()
        }
    }

    private func notifyAboutNewAttention(in scanned: [AgentSession]) {
        let current = Set(scanned.filter { $0.status.needsAttention }.map(\.id))
        for session in scanned where current.contains(session.id) && !attentionIDs.contains(session.id) {
            onAttentionNeeded?(session)
        }
        attentionIDs = current
    }

    private func updateBadge() {
        let attention = attentionCount
        let finished = sessions.reduce(0) { $0 + ($1.status == .finished ? 1 : 0) }
        let next: BadgeState = attention > 0 ? .attention(attention) : finished > 0 ? .finished(finished) : .none
        guard next != badge else { return }
        badge = next
        Log.agents.info("badge: \(String(describing: next), privacy: .public) with \(self.sessions.count, privacy: .public) session(s)")
        onBadgeChange?(next)
    }
}
