import Foundation

/// Working-tree state from `git status --porcelain=v2 --branch`.
public struct GitRepoStatus: Equatable, Sendable {
    /// Local branch name, or `nil` when HEAD is detached or has no commits yet.
    public var branch: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    /// Changed entries with something staged in the index.
    public var stagedCount: Int
    /// Changed entries with an unstaged change in the working tree.
    public var modifiedCount: Int
    public var untrackedCount: Int
    public var conflictedCount: Int
    /// Every changed file, counted once even when it is both staged and modified.
    public var totalChanges: Int
    /// The first changed paths in git's order. The parser caps the list; the counts are not capped.
    public var changes: [GitChange]

    public init(
        branch: String? = nil,
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        stagedCount: Int = 0,
        modifiedCount: Int = 0,
        untrackedCount: Int = 0,
        conflictedCount: Int = 0,
        totalChanges: Int = 0,
        changes: [GitChange] = []
    ) {
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.stagedCount = stagedCount
        self.modifiedCount = modifiedCount
        self.untrackedCount = untrackedCount
        self.conflictedCount = conflictedCount
        self.totalChanges = totalChanges
        self.changes = changes
    }

    public var isClean: Bool { totalChanges == 0 }
}

/// One changed path.
public struct GitChange: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted
    }

    public var id: String { path }
    public var path: String
    /// The previous path, for renames and copies.
    public var originalPath: String?
    public var kind: Kind
    /// Whether the change is staged in the index.
    public var isStaged: Bool

    public init(path: String, originalPath: String? = nil, kind: Kind, isStaged: Bool) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.isStaged = isStaged
    }
}

/// A commit from `git log`.
public struct GitCommit: Equatable, Sendable, Identifiable {
    public var id: String { hash }
    public var hash: String
    public var shortHash: String
    public var author: String
    /// Git's relative date, e.g. "2 hours ago".
    public var relativeDate: String
    public var subject: String

    public init(hash: String, shortHash: String, author: String, relativeDate: String, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.author = author
        self.relativeDate = relativeDate
        self.subject = subject
    }
}

/// A local branch from `git for-each-ref`.
public struct GitBranch: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Relative date of the branch's last commit.
    public var relativeDate: String
    public var ahead: Int
    public var behind: Int
    /// The configured upstream no longer exists on the remote.
    public var upstreamIsGone: Bool

    public init(name: String, relativeDate: String, ahead: Int = 0, behind: Int = 0, upstreamIsGone: Bool = false) {
        self.name = name
        self.relativeDate = relativeDate
        self.ahead = ahead
        self.behind = behind
        self.upstreamIsGone = upstreamIsGone
    }
}

/// An open pull request from `gh pr list`.
public struct GitPullRequest: Equatable, Sendable, Identifiable {
    public enum ReviewDecision: String, Equatable, Sendable {
        case approved = "APPROVED"
        case changesRequested = "CHANGES_REQUESTED"
        case reviewRequired = "REVIEW_REQUIRED"
    }

    public var id: Int { number }
    public var number: Int
    public var title: String
    public var headBranch: String
    public var url: String
    public var isDraft: Bool
    public var authorLogin: String?
    public var reviewDecision: ReviewDecision?

    public init(
        number: Int,
        title: String,
        headBranch: String,
        url: String,
        isDraft: Bool,
        authorLogin: String? = nil,
        reviewDecision: ReviewDecision? = nil
    ) {
        self.number = number
        self.title = title
        self.headBranch = headBranch
        self.url = url
        self.isDraft = isDraft
        self.authorLogin = authorLogin
        self.reviewDecision = reviewDecision
    }
}

/// Everything the Git tab shows for one repository.
public struct GitRepoSnapshot: Identifiable, Equatable, Sendable {
    /// The repository root, normalised by `GitRepoCatalog`.
    public var root: String
    /// `nil` when the status could not be read (not a repository, git failed, or timed out).
    public var status: GitRepoStatus?
    public var commits: [GitCommit]
    public var branches: [GitBranch]
    /// Empty when GitHub CLI is missing, not signed in, or the remote is not GitHub.
    public var pullRequests: [GitPullRequest]

    public var id: String { root }

    public var name: String {
        let last = URL(fileURLWithPath: root).lastPathComponent
        return last.isEmpty ? root : last
    }

    public init(
        root: String,
        status: GitRepoStatus?,
        commits: [GitCommit] = [],
        branches: [GitBranch] = [],
        pullRequests: [GitPullRequest] = []
    ) {
        self.root = root
        self.status = status
        self.commits = commits
        self.branches = branches
        self.pullRequests = pullRequests
    }
}

/// The repositories the user added by hand, as stored in `git-repos.json`.
public struct GitRepoList: Codable, Equatable, Sendable {
    public var paths: [String]

    public init(paths: [String]) {
        self.paths = paths
    }
}

/// Keeps repository roots unique, so one repository is never shown twice.
public enum GitRepoCatalog {
    /// A comparable form of a path: trimmed, absolute and without a trailing slash.
    public static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    /// Normalises each path and keeps the first occurrence of every repository, in order.
    public static func unique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let normalized = normalized(path)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
