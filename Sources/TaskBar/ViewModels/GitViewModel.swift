import AppKit
import Observation
import TaskBarCore

/// The Git tab's repositories: the folders of current Claude Code sessions plus the ones the user
/// added, refreshed only while the tab is on screen.
///
/// Nothing runs while the popover is closed: `setVisible(_:)` starts a 30-second refresh loop
/// when the tab appears and cancels it when the tab goes away.
@MainActor
@Observable
final class GitViewModel {
    /// Latest state of every repository, in list order.
    private(set) var snapshots: [GitRepoSnapshot] = []
    /// Set after the first refresh, so the list does not flash "No repositories" while loading.
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false
    /// True when GitHub CLI is not installed, so the pull request section can say how to enable it.
    private(set) var isGitHubCLIMissing = false
    /// The repository open in the detail view, if any.
    private(set) var selectedRoot: String?
    /// Explains why a folder the user picked was not added.
    private(set) var notice: String?

    @ObservationIgnored private let agents: AgentsViewModel
    @ObservationIgnored private let store: JSONFileStore<GitRepoList>
    /// Repositories the user added by hand, in order.
    @ObservationIgnored private var addedRoots: [String]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isListVisible = false
    @ObservationIgnored private var needsRefresh = false

    private static let refreshInterval: Duration = .seconds(30)

    init(paths: AppPaths, agents: AgentsViewModel) {
        self.agents = agents
        let store = JSONFileStore<GitRepoList>(url: paths.gitReposFile)
        self.store = store
        let outcome = store.loadOrRecover(default: GitRepoList(paths: []))
        addedRoots = GitRepoCatalog.unique(outcome.document.paths)
        if let failure = outcome.failureDescription {
            Log.app.error("reading git-repos.json failed: \(failure, privacy: .public)")
        }
    }

    // MARK: Visibility

    /// Starts or stops the refresh loop. Called whenever the Git tab appears or disappears.
    func setVisible(_ visible: Bool) {
        guard visible != isListVisible else { return }
        isListVisible = visible
        pollTask?.cancel()
        pollTask = nil
        guard visible else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    // MARK: Refreshing

    /// Reloads every repository. A request that arrives mid-refresh runs once more afterwards,
    /// so a repository added during a refresh appears without waiting for the next tick.
    func refresh() async {
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            needsRefresh = false
            await loadRepositories()
        } while needsRefresh && !Task.isCancelled
    }

    private func loadRepositories() async {
        let gitHubCLI = GitHubCLILocator.locate()
        isGitHubCLIMissing = gitHubCLI == nil
        let client = GitClient(gitHubCLI: gitHubCLI)

        // Session folders may repeat across sessions, so resolve each one once.
        let folders = Array(Set(agents.sessions.map(\.cwd))).sorted()
        let sessionRoots = await Self.repositoryRoots(for: folders, client: client)
        let roots = GitRepoCatalog.unique(sessionRoots + addedRoots)
        guard !Task.isCancelled else { return }

        snapshots = await Self.snapshots(for: roots, client: client)
        hasLoaded = true
        if let selectedRoot, !roots.contains(selectedRoot) {
            self.selectedRoot = nil
        }
    }

    private static func repositoryRoots(for folders: [String], client: GitClient) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            for folder in folders {
                group.addTask { await client.repositoryRoot(containing: folder) }
            }
            var roots: [String] = []
            for await root in group {
                if let root { roots.append(root) }
            }
            return roots
        }
    }

    /// Snapshots run concurrently; the result keeps the order of `roots`.
    private static func snapshots(for roots: [String], client: GitClient) async -> [GitRepoSnapshot] {
        let byRoot = await withTaskGroup(of: GitRepoSnapshot.self) { group in
            for root in roots {
                group.addTask { await client.snapshot(of: root) }
            }
            var result: [String: GitRepoSnapshot] = [:]
            for await snapshot in group {
                result[snapshot.root] = snapshot
            }
            return result
        }
        return roots.compactMap { byRoot[$0] }
    }

    // MARK: Lookup

    func snapshot(for root: String) -> GitRepoSnapshot? {
        snapshots.first { $0.root == root }
    }

    func isAdded(_ root: String) -> Bool {
        addedRoots.contains(root)
    }

    // MARK: Adding and removing

    /// Shows the folder picker and adds the chosen folders. Call it while the popover is held open.
    func chooseRepositories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose the folders of the Git repositories to show."
        guard panel.runModal() == .OK else { return }

        let folders = panel.urls.map(\.path)
        Task { await add(folders: folders) }
    }

    /// Adds the repository each folder belongs to. Folders outside any repository are reported.
    func add(folders: [String]) async {
        let client = GitClient(gitHubCLI: nil)
        let roots = await Self.repositoryRoots(for: folders, client: client)
        let skipped = folders.count - roots.count
        if !roots.isEmpty {
            addedRoots = GitRepoCatalog.unique(addedRoots + roots)
            persist()
        }
        notice = skipped > 0
            ? (skipped == 1 ? "That folder is not inside a Git repository." : "\(skipped) folders are not inside a Git repository.")
            : nil
        await refresh()
    }

    func dismissNotice() {
        notice = nil
    }

    /// Removes a repository the user added. Repositories that appear because of a Claude Code
    /// session stay listed while that session is open.
    func removeRepository(_ root: String) {
        addedRoots.removeAll { $0 == root }
        persist()
        if selectedRoot == root { selectedRoot = nil }
        Task { await refresh() }
    }

    private func persist() {
        do {
            try store.save(GitRepoList(paths: addedRoots))
        } catch {
            Log.app.error("saving git-repos.json failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Navigation

    func select(_ root: String?) {
        selectedRoot = root
    }

    /// Escape support: closes the detail view. Returns whether there was one to close.
    func closeDetail() -> Bool {
        guard selectedRoot != nil else { return false }
        selectedRoot = nil
        return true
    }

    // MARK: Actions

    func openInFinder(_ root: String) {
        Opener.open(URL(fileURLWithPath: root, isDirectory: true))
    }

    /// Opens a new Terminal window in the repository. Returns `false` when Terminal is missing.
    @discardableResult
    func openInTerminal(_ root: String) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return false
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: root, isDirectory: true)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
        return true
    }

    func copyPath(_ root: String) {
        Opener.copyToPasteboard(root)
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        Opener.open(url)
    }
}
