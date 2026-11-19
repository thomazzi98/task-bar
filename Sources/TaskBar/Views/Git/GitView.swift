import SwiftUI
import TaskBarCore

/// The Git tab: one card per repository, and a detail screen for the one picked.
struct GitView: View {
    @Environment(GitViewModel.self) private var git

    var body: some View {
        Group {
            if let root = git.selectedRoot, let snapshot = git.snapshot(for: root) {
                GitRepoDetailView(snapshot: snapshot)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: git.selectedRoot)
    }

    private var list: some View {
        VStack(spacing: 0) {
            Toolbar()
                .padding(.horizontal, Design.gutter)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if let notice = git.notice {
                NoticeBanner(text: notice, symbol: "info.circle", tint: .secondary, onDismiss: git.dismissNotice)
                    .padding(.horizontal, Design.gutter)
                    .padding(.top, 6)
            }

            if !git.hasLoaded {
                EmptyStateView(symbol: "arrow.triangle.branch", title: "Loading repositories")
            } else if git.snapshots.isEmpty {
                EmptyStateView(
                    symbol: "arrow.triangle.branch",
                    title: "No repositories",
                    message: "Projects of running Claude Code sessions show up here. Add any other folder with Add repository."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(git.snapshots) { snapshot in
                            RepoCard(snapshot: snapshot)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                if git.isGitHubCLIMissing {
                    Text("Install GitHub CLI (gh) to see pull requests.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)
                }
            }
        }
    }
}

/// Title, refresh and add controls above the repository list.
private struct Toolbar: View {
    @Environment(GitViewModel.self) private var git
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            Text("Repositories")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                Task { await git.refresh() }
            }
            .opacity(git.isRefreshing ? 0.4 : 1)
            PillButton(title: "Add repository", symbol: "plus", isProminent: true) {
                // The folder panel takes focus away from the popover, which would otherwise close.
                Task { await appState.holdingOpen { git.chooseRepositories() } }
            }
        }
    }
}

/// One repository in the list: name, branch, a status chip and its open pull requests.
private struct RepoCard: View {
    let snapshot: GitRepoSnapshot

    @Environment(GitViewModel.self) private var git
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(snapshot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                summaryChip
            }

            HStack(spacing: 9) {
                Label(branchText, systemImage: "arrow.triangle.branch")
                    .lineLimit(1)
                if !snapshot.pullRequests.isEmpty {
                    let count = snapshot.pullRequests.count
                    Label("\(count) open PR\(count == 1 ? "" : "s")", systemImage: "arrow.triangle.pull")
                }
            }
            .labelStyle(CompactLabelStyle())
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            if snapshot.status == nil {
                Text("Could not read this repository.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { git.select(snapshot.root) }
        .hoverHighlight()
        .contextMenu {
            Button("Open in Finder") { git.openInFinder(snapshot.root) }
            Button("Copy Path") {
                git.copyPath(snapshot.root)
                appState.showToast("Path copied")
            }
            if git.isAdded(snapshot.root) {
                Divider()
                Button("Remove from List", role: .destructive) { git.removeRepository(snapshot.root) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var branchText: String {
        guard let status = snapshot.status else { return "unknown branch" }
        let name = status.branch ?? "detached HEAD"
        let tracking = GitFormat.aheadBehind(ahead: status.ahead, behind: status.behind)
        return tracking.isEmpty ? name : "\(name)  \(tracking)"
    }

    private var summaryChip: some View {
        let summary = GitFormat.summary(for: snapshot.status)
        return Chip(text: summary.text, tint: summary.tint)
    }
}

/// Text shared by the list and the detail view.
enum GitFormat {
    /// `↑2 ↓1`, or an empty string when the branch is level with its upstream.
    static func aheadBehind(ahead: Int, behind: Int) -> String {
        var parts: [String] = []
        if ahead > 0 { parts.append("↑\(ahead)") }
        if behind > 0 { parts.append("↓\(behind)") }
        return parts.joined(separator: " ")
    }

    /// The colour-coded chip for a repository's state.
    static func summary(for status: GitRepoStatus?) -> (text: String, tint: Color) {
        guard let status else { return ("unavailable", .secondary) }
        if status.conflictedCount > 0 {
            return ("\(status.conflictedCount) conflict\(status.conflictedCount == 1 ? "" : "s")", .red)
        }
        if status.totalChanges > 0 {
            return ("\(status.totalChanges) change\(status.totalChanges == 1 ? "" : "s")", .orange)
        }
        return ("clean", .green)
    }

    static func label(for kind: GitChange.Kind) -> String {
        switch kind {
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .typeChanged: "Type changed"
        case .untracked: "Untracked"
        case .conflicted: "Conflict"
        }
    }

    static func tint(for kind: GitChange.Kind) -> Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted, .conflicted: .red
        case .modified, .renamed, .copied, .typeChanged: .orange
        }
    }
}
