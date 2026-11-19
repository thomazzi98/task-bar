import Foundation

/// Runs git and GitHub CLI commands for the Git tab. Every command has a timeout, and a failed or
/// timed-out command contributes nothing rather than failing the whole repository.
public struct GitClient: Sendable {
    /// `nil` when GitHub CLI is not installed, in which case pull requests are skipped.
    public let gitHubCLI: URL?

    public init(gitHubCLI: URL?) {
        self.gitHubCLI = gitHubCLI
    }

    /// The top-level folder of the repository containing `directory`, or `nil` when it is not
    /// inside a repository.
    public func repositoryRoot(containing directory: String) async -> String? {
        guard let data = await Self.run(
            GitCommands.repositoryRoot(of: directory),
            executable: GitCommands.gitExecutable,
            in: directory,
            timeout: GitCommands.gitTimeout
        ) else { return nil }
        let root = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = GitRepoCatalog.normalized(root)
        return normalized.isEmpty ? nil : normalized
    }

    /// Reads status, commits, branches and pull requests for one repository. The local commands
    /// run concurrently, and the GitHub call runs alongside them.
    public func snapshot(of root: String) async -> GitRepoSnapshot {
        async let statusData = Self.run(
            GitCommands.status(in: root), executable: GitCommands.gitExecutable, in: root, timeout: GitCommands.gitTimeout
        )
        async let logData = Self.run(
            GitCommands.log(in: root), executable: GitCommands.gitExecutable, in: root, timeout: GitCommands.gitTimeout
        )
        async let branchData = Self.run(
            GitCommands.branches(in: root), executable: GitCommands.gitExecutable, in: root, timeout: GitCommands.gitTimeout
        )
        async let pullRequests = loadPullRequests(in: root)

        let status = await statusData.map { GitStatusParser.parse(String(decoding: $0, as: UTF8.self)) }
        let commits = await logData.map { GitLogParser.parse(String(decoding: $0, as: UTF8.self)) } ?? []
        let branches = await branchData.map { GitBranchParser.parse(String(decoding: $0, as: UTF8.self)) } ?? []

        return GitRepoSnapshot(
            root: root,
            status: status,
            commits: commits,
            branches: branches,
            pullRequests: await pullRequests
        )
    }

    // MARK: Private

    private func loadPullRequests(in root: String) async -> [GitPullRequest] {
        // `gh` fails outside GitHub repositories and when not signed in; both mean "show nothing".
        guard let gitHubCLI, let data = await Self.run(
            GitCommands.pullRequests(),
            executable: gitHubCLI,
            in: root,
            timeout: GitCommands.pullRequestTimeout
        ) else { return [] }
        return (try? GitHubPullRequestParser.parse(data)) ?? []
    }

    /// Returns standard output for a successful, in-time run, otherwise `nil`.
    private static func run(
        _ arguments: [String],
        executable: URL,
        in directory: String,
        timeout: TimeInterval
    ) async -> Data? {
        guard let output = try? await ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            input: Data(),
            workingDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            timeout: timeout
        ) else { return nil }
        guard !output.timedOut, output.status == 0 else { return nil }
        return output.standardOutput
    }
}
