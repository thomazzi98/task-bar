import SwiftUI
import TaskBarCore

/// One repository in depth: changed files, recent commits, branches and open pull requests.
struct GitRepoDetailView: View {
    let snapshot: GitRepoSnapshot

    @Environment(GitViewModel.self) private var git
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            BackBar(title: "Git", onBack: { git.select(nil) }) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") {
                    Task { await git.refresh() }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    actions
                    if snapshot.status == nil {
                        NoticeBanner(text: "Could not read this repository. It may have moved or git timed out.")
                    }
                    changesSection
                    commitsSection
                    branchesSection
                    pullRequestsSection
                }
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 12)
            }
        }
    }

    // MARK: Header and actions

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snapshot.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if let status = snapshot.status {
                HStack(spacing: 6) {
                    Label(status.branch ?? "detached HEAD", systemImage: "arrow.triangle.branch")
                        .lineLimit(1)
                    let tracking = GitFormat.aheadBehind(ahead: status.ahead, behind: status.behind)
                    if !tracking.isEmpty {
                        Text(tracking).monospacedDigit()
                    }
                    if let upstream = status.upstream {
                        Text("· \(upstream)").lineLimit(1).truncationMode(.middle)
                    }
                }
                .labelStyle(CompactLabelStyle())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Text(abbreviatedPath)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            PillButton(title: "Finder", symbol: "folder") { git.openInFinder(snapshot.root) }
            PillButton(title: "Terminal", symbol: "terminal") {
                if !git.openInTerminal(snapshot.root) {
                    appState.showToast("Terminal is not installed")
                }
            }
            PillButton(title: "Copy path", symbol: "doc.on.doc") {
                git.copyPath(snapshot.root)
                appState.showToast("Path copied")
            }
            Spacer(minLength: 0)
            if git.isAdded(snapshot.root) {
                PillButton(title: "Remove", symbol: "minus.circle", tint: .red) {
                    git.removeRepository(snapshot.root)
                }
            }
        }
    }

    private var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return snapshot.root.hasPrefix(home) ? "~" + snapshot.root.dropFirst(home.count) : snapshot.root
    }

    // MARK: Sections

    @ViewBuilder
    private var changesSection: some View {
        if let status = snapshot.status {
            section(title: "Changes", detail: status.totalChanges > 0 ? "\(status.totalChanges)" : nil) {
                if status.changes.isEmpty {
                    Text("Nothing changed. Working tree is clean.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(status.changes) { change in
                            HStack(spacing: 7) {
                                Chip(text: GitFormat.label(for: change.kind), tint: GitFormat.tint(for: change.kind))
                                Text(change.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                if change.isStaged {
                                    Text("staged")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .help(change.originalPath.map { "Renamed from \($0)" } ?? change.path)
                        }
                        if status.totalChanges > status.changes.count {
                            Text("and \(status.totalChanges - status.changes.count) more")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var commitsSection: some View {
        if !snapshot.commits.isEmpty {
            section(title: "Recent commits", detail: nil) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.commits) { commit in
                        HStack(alignment: .top, spacing: 8) {
                            Text(commit.shortHash)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1.5) {
                                Text(commit.subject)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Text("\(commit.author) · \(commit.relativeDate)")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var branchesSection: some View {
        if !snapshot.branches.isEmpty {
            section(title: "Branches", detail: nil) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.branches) { branch in
                        HStack(spacing: 7) {
                            Image(systemName: branch.name == snapshot.status?.branch ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                                .foregroundStyle(branch.name == snapshot.status?.branch ? Color.accentColor : .secondary)
                            Text(branch.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if branch.upstreamIsGone {
                                Chip(text: "upstream gone", tint: .orange)
                            }
                            Spacer(minLength: 4)
                            let tracking = GitFormat.aheadBehind(ahead: branch.ahead, behind: branch.behind)
                            if !tracking.isEmpty {
                                Text(tracking)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text(branch.relativeDate)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pullRequestsSection: some View {
        if !snapshot.pullRequests.isEmpty {
            section(title: "Open pull requests", detail: "\(snapshot.pullRequests.count)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.pullRequests) { pull in
                        PullRequestRow(pull: pull)
                    }
                }
            }
        } else if git.isGitHubCLIMissing {
            section(title: "Open pull requests", detail: nil) {
                Text("Install GitHub CLI (gh) to see pull requests.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func section(title: String, detail: String?, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }
}

/// A pull request that opens on GitHub when clicked.
private struct PullRequestRow: View {
    let pull: GitPullRequest

    @Environment(GitViewModel.self) private var git

    var body: some View {
        Button {
            git.openURL(pull.url)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(pull.number)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pull.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if pull.isDraft {
                        Chip(text: "Draft", tint: .secondary)
                    }
                    reviewChip
                }
                Text([pull.authorLogin, pull.headBranch].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help("Open on GitHub")
    }

    @ViewBuilder
    private var reviewChip: some View {
        switch pull.reviewDecision {
        case .approved: Chip(text: "Approved", tint: .green)
        case .changesRequested: Chip(text: "Changes requested", tint: .red)
        case .reviewRequired: Chip(text: "Review required", tint: .orange)
        case nil: EmptyView()
        }
    }
}
