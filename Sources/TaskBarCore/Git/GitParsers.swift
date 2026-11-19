import Foundation

/// The git and GitHub CLI invocations the Git tab makes, and their limits.
public enum GitCommands {
    public static let gitExecutable = URL(fileURLWithPath: "/usr/bin/git")
    /// Git commands are local and finish in milliseconds; this only guards against a hang.
    public static let gitTimeout: TimeInterval = 5
    /// GitHub is a network call, so it gets more room than the local git commands.
    public static let pullRequestTimeout: TimeInterval = 10
    public static let commitLimit = 8
    public static let branchLimit = 10
    public static let pullRequestLimit = 10

    static let pullRequestFields = "number,title,headRefName,url,isDraft,author,reviewDecision"
    static let recordSeparator = "%x1f"

    public static func repositoryRoot(of directory: String) -> [String] {
        ["-C", directory, "rev-parse", "--show-toplevel"]
    }

    /// `-z` ends every record with a NUL and never quotes a path, so names with spaces, quotes or
    /// non-ASCII characters come through exactly as they are on disk.
    public static func status(in root: String) -> [String] {
        ["-C", root, "status", "--porcelain=v2", "--branch", "-z"]
    }

    public static func log(in root: String) -> [String] {
        [
            "-C", root, "log", "-n", String(commitLimit),
            "--format=%H\(recordSeparator)%h\(recordSeparator)%an\(recordSeparator)%ar\(recordSeparator)%s"
        ]
    }

    public static func branches(in root: String) -> [String] {
        [
            "-C", root, "for-each-ref", "--sort=-committerdate",
            // for-each-ref does not expand %xx escapes, so it separates fields with a literal tab.
            // Git forbids tabs in ref names, and the date and track text never contain one.
            "--format=%(refname:short)\t%(committerdate:relative)\t%(upstream:track)",
            "refs/heads"
        ]
    }

    public static func pullRequests() -> [String] {
        ["pr", "list", "--limit", String(pullRequestLimit), "--json", pullRequestFields]
    }
}

/// Reads `git status --porcelain=v2 --branch -z`.
public enum GitStatusParser {
    public static let defaultChangeLimit = 20

    /// Parses the NUL-separated output into counts and the first `changeLimit` changed paths.
    /// A rename or copy is followed by its original path as a record of its own. Unknown lines
    /// are skipped, so a newer git never breaks the view.
    public static func parse(_ output: String, changeLimit: Int = defaultChangeLimit) -> GitRepoStatus {
        var status = GitRepoStatus()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let line = records[index]
            index += 1
            if line.hasPrefix("# ") {
                parseHeader(line, into: &status)
                continue
            }
            guard let kind = line.first else { continue }
            let entry: Entry?
            switch kind {
            case "1":
                entry = ordinaryEntry(line)
            case "2":
                // Always consume the original path, even when this entry turns out unreadable.
                let original = index < records.count ? String(records[index]) : nil
                index += 1
                entry = renamedEntry(line, originalPath: original)
            case "u": entry = unmergedEntry(line)
            case "?": entry = untrackedEntry(line)
            default: entry = nil // Ignored files (`!`) are not requested, so they are skipped.
            }
            guard let entry else { continue }
            record(entry, into: &status, changeLimit: changeLimit)
        }
        return status
    }

    /// One parsed status line, with the flags that feed the counts.
    private struct Entry {
        var change: GitChange
        var hasIndexChange = false
        var hasWorktreeChange = false
    }

    private static func parseHeader(_ line: Substring, into status: inout GitRepoStatus) {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.head":
            // Git reports "(detached)" or "(initial)" in place of a branch name.
            status.branch = value.hasPrefix("(") ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            // "+2 -1": commits ahead of, then behind, the upstream.
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                status.ahead = Int(counts[0].dropFirst()) ?? 0
                status.behind = Int(counts[1].dropFirst()) ?? 0
            }
        default:
            break
        }
    }

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func ordinaryEntry(_ line: Substring) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9, let codes = statusCodes(fields[1]) else { return nil }
        let hasIndexChange = codes.index != "."
        let hasWorktreeChange = codes.worktree != "."
        return Entry(
            change: GitChange(
                path: String(fields[8]),
                kind: kind(index: codes.index, worktree: codes.worktree),
                isStaged: hasIndexChange
            ),
            hasIndexChange: hasIndexChange,
            hasWorktreeChange: hasWorktreeChange
        )
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>`, with the original path in the
    /// record that follows.
    private static func renamedEntry(_ line: Substring, originalPath: String?) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
        guard fields.count == 10, let codes = statusCodes(fields[1]) else { return nil }
        // The score field starts with R (renamed) or C (copied).
        let isCopy = fields[8].first == "C"
        let hasIndexChange = codes.index != "."
        let hasWorktreeChange = codes.worktree != "."
        return Entry(
            change: GitChange(
                path: String(fields[9]),
                originalPath: originalPath,
                kind: isCopy ? .copied : .renamed,
                isStaged: hasIndexChange
            ),
            hasIndexChange: hasIndexChange,
            hasWorktreeChange: hasWorktreeChange
        )
    }

    /// `u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>`
    private static func unmergedEntry(_ line: Substring) -> Entry? {
        let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return nil }
        return Entry(change: GitChange(path: String(fields[10]), kind: .conflicted, isStaged: false))
    }

    /// `? <path>`
    private static func untrackedEntry(_ line: Substring) -> Entry? {
        let path = line.dropFirst(2)
        guard !path.isEmpty else { return nil }
        return Entry(change: GitChange(path: String(path), kind: .untracked, isStaged: false))
    }

    private static func statusCodes(_ field: Substring) -> (index: Character, worktree: Character)? {
        let characters = Array(field)
        guard characters.count == 2 else { return nil }
        return (characters[0], characters[1])
    }

    /// The index code wins when both are set, since that is what the user staged.
    private static func kind(index: Character, worktree: Character) -> GitChange.Kind {
        switch index == "." ? worktree : index {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        default: .modified
        }
    }

    private static func record(_ entry: Entry, into status: inout GitRepoStatus, changeLimit: Int) {
        status.totalChanges += 1
        switch entry.change.kind {
        case .conflicted:
            status.conflictedCount += 1
        case .untracked:
            status.untrackedCount += 1
        default:
            // A file can be staged and edited again, so it may count under both.
            if entry.hasIndexChange { status.stagedCount += 1 }
            if entry.hasWorktreeChange { status.modifiedCount += 1 }
        }
        if status.changes.count < changeLimit {
            status.changes.append(entry.change)
        }
    }
}

/// Reads `git log --format=%H%x1f%h%x1f%an%x1f%ar%x1f%s`.
public enum GitLogParser {
    public static func parse(_ output: String) -> [GitCommit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, !fields[0].isEmpty else { return nil }
            return GitCommit(
                hash: String(fields[0]),
                shortHash: String(fields[1]),
                author: String(fields[2]),
                relativeDate: String(fields[3]),
                subject: String(fields[4])
            )
        }
    }
}

/// Reads the `git for-each-ref` output of `GitCommands.branches`, one tab-separated branch per line.
public enum GitBranchParser {
    public static func parse(_ output: String, limit: Int = GitCommands.branchLimit) -> [GitBranch] {
        let branches: [GitBranch] = output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty else { return nil }
            let track = parseTrack(String(fields[2]))
            return GitBranch(
                name: String(fields[0]),
                relativeDate: String(fields[1]),
                ahead: track.ahead,
                behind: track.behind,
                upstreamIsGone: track.gone
            )
        }
        return Array(branches.prefix(limit))
    }

    /// Reads the bracketed track text, such as `[ahead 2, behind 1]`, `[gone]` or an empty string.
    static func parseTrack(_ text: String) -> (ahead: Int, behind: Int, gone: Bool) {
        var result: (ahead: Int, behind: Int, gone: Bool) = (0, 0, false)
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        for part in inner.split(separator: ",") {
            let words = part.split(separator: " ")
            guard let label = words.first else { continue }
            let count = Int(words.dropFirst().first ?? "") ?? 0
            switch label {
            case "ahead": result.ahead = count
            case "behind": result.behind = count
            case "gone": result.gone = true
            default: continue
            }
        }
        return result
    }
}

/// Reads `gh pr list --json number,title,headRefName,url,isDraft,author,reviewDecision`.
public enum GitHubPullRequestParser {
    public static func parse(_ data: Data) throws -> [GitPullRequest] {
        guard !data.isEmpty else { return [] }
        let raw = try JSONDecoder().decode([Raw].self, from: data)
        return raw.map { item in
            GitPullRequest(
                number: item.number,
                title: item.title,
                headBranch: item.headRefName,
                url: item.url,
                isDraft: item.isDraft,
                authorLogin: item.author?.login,
                // GitHub sends an empty string when no review has been requested.
                reviewDecision: item.reviewDecision.flatMap(GitPullRequest.ReviewDecision.init(rawValue:))
            )
        }
    }

    private struct Raw: Decodable {
        var number: Int
        var title: String
        var headRefName: String
        var url: String
        var isDraft: Bool
        var author: Author?
        var reviewDecision: String?

        struct Author: Decodable {
            var login: String?
        }
    }
}

/// Finds the GitHub CLI binary. A Mac app launched from Finder has a short PATH, so the usual
/// Homebrew and per-user locations are checked explicitly, the same way `ClaudeCLILocator` does.
public enum GitHubCLILocator {
    public static func locate(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        ExecutableLocator.first(in: candidates(path: path, home: home), fileManager: fileManager)
    }

    static func candidates(path: String, home: URL) -> [URL] {
        var urls = [
            home.appendingPathComponent(".local/bin/gh"),
            URL(fileURLWithPath: "/opt/homebrew/bin/gh"),
            URL(fileURLWithPath: "/usr/local/bin/gh")
        ]
        urls += path.split(separator: ":").map { directory in
            URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("gh")
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }
}
