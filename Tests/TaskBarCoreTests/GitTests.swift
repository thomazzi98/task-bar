import Foundation
import Testing
@testable import TaskBarCore

@Suite("Git status parsing")
struct GitStatusParserTests {
    /// `git status --porcelain=v2 --branch -z` output covering every entry type: records end in
    /// NUL, and a rename's original path is a record of its own. Paths hold spaces and quotes.
    private let mixed = [
        "# branch.oid 9fceb02d0ae598e95dc970b74767f19372d61af8",
        "# branch.head feature/login",
        "# branch.upstream origin/feature/login",
        "# branch.ab +2 -1",
        "1 .M N... 100644 100644 100644 abc1234 def5678 Sources/App/Login.swift",
        "1 M. N... 100644 100644 100644 aaa1111 bbb2222 README.md",
        "1 MM N... 100644 100644 100644 ccc3333 ddd4444 Package.swift",
        "1 A. N... 000000 100644 100644 0000000 eee5555 Sources/App/New File.swift",
        "1 .D N... 100644 100644 000000 fff6666 0000000 docs/old.md",
        "2 R. N... 100644 100644 100644 111aaaa 222bbbb R100 Sources/App/Renamed File.swift",
        "Sources/App/Original File.swift",
        "u UU N... 100644 100644 100644 100644 333cccc 444dddd 555eeee Sources/App/Conflict.swift",
        "? scratch notes.txt",
        "? say \"hi\".txt",
        "? .env.local"
    ].joined(separator: "\0") + "\0"

    @Test func readsBranchUpstreamAndDivergence() {
        let status = GitStatusParser.parse(mixed)
        #expect(status.branch == "feature/login")
        #expect(status.upstream == "origin/feature/login")
        #expect(status.ahead == 2)
        #expect(status.behind == 1)
    }

    @Test func countsEveryEntryKindOnce() {
        let status = GitStatusParser.parse(mixed)
        #expect(status.totalChanges == 10)
        // README (M.), Package (MM), New File (A.) and Renamed (R.) have something staged.
        #expect(status.stagedCount == 4)
        // Login (.M), Package (MM) and old.md (.D) have an unstaged edit.
        #expect(status.modifiedCount == 3)
        #expect(status.untrackedCount == 3)
        #expect(status.conflictedCount == 1)
        #expect(!status.isClean)
    }

    @Test func listsPathsWithTheirState() throws {
        let changes = GitStatusParser.parse(mixed).changes
        #expect(changes.count == 10)

        let login = try #require(changes.first { $0.path == "Sources/App/Login.swift" })
        #expect(login.kind == .modified)
        #expect(!login.isStaged)

        let added = try #require(changes.first { $0.path == "Sources/App/New File.swift" })
        #expect(added.kind == .added)
        #expect(added.isStaged)

        let deleted = try #require(changes.first { $0.path == "docs/old.md" })
        #expect(deleted.kind == .deleted)

        let renamed = try #require(changes.first { $0.path == "Sources/App/Renamed File.swift" })
        #expect(renamed.kind == .renamed)
        #expect(renamed.originalPath == "Sources/App/Original File.swift")
        #expect(renamed.isStaged)

        let conflict = try #require(changes.first { $0.path == "Sources/App/Conflict.swift" })
        #expect(conflict.kind == .conflicted)

        let untracked = try #require(changes.first { $0.path == "scratch notes.txt" })
        #expect(untracked.kind == .untracked)

        // Quotes and spaces arrive exactly as on disk, with no C-style quoting.
        let quoted = try #require(changes.first { $0.path == #"say "hi".txt"# })
        #expect(quoted.kind == .untracked)
    }

    @Test func aRenamesOriginalPathIsNotReadAsAnEntry() {
        let output = "2 R. N... 100644 100644 100644 111aaaa 222bbbb R100 New.swift\0Old.swift\0? extra.txt\0"
        let status = GitStatusParser.parse(output)
        #expect(status.totalChanges == 2)
        #expect(status.changes.map(\.path) == ["New.swift", "extra.txt"])
        #expect(status.changes.first?.originalPath == "Old.swift")
    }

    @Test func capsTheListButNotTheCounts() {
        var records = ["# branch.head main"]
        records += (1...25).map { "? untracked-\($0).txt" }
        let status = GitStatusParser.parse(records.joined(separator: "\0") + "\0", changeLimit: 20)
        #expect(status.totalChanges == 25)
        #expect(status.untrackedCount == 25)
        #expect(status.changes.count == 20)
        #expect(status.changes.first?.path == "untracked-1.txt")
    }

    @Test func readsDetachedHeadWithoutUpstream() {
        let output = "# branch.oid 9fceb02d0ae598e95dc970b74767f19372d61af8\0# branch.head (detached)\0"
        let status = GitStatusParser.parse(output)
        #expect(status.branch == nil)
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
        #expect(status.isClean)
    }

    @Test func treatsAnUnbornBranchAsNoBranch() {
        let status = GitStatusParser.parse("# branch.oid (initial)\0# branch.head (initial)\0")
        #expect(status.branch == nil)
        #expect(status.isClean)
    }

    @Test func skipsUnknownLinesWithoutFailing() {
        let output = "# some.future.header x\0zz nonsense\01 short\0? ok.txt\0"
        let status = GitStatusParser.parse(output)
        #expect(status.totalChanges == 1)
        #expect(status.changes.map(\.path) == ["ok.txt"])
    }
}

@Suite("Git log, branch and pull request parsing")
struct GitHistoryParserTests {
    private let sep = "\u{1F}"

    @Test func parsesCommitsWithSeparators() {
        let output = [
            ["9f3c2a1e4b7d8c6f0a1b2c3d4e5f60718293a4b5", "9f3c2a1", "Ana Souza", "2 hours ago", "Fix flaky transcript test"],
            ["1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f6071829303", "1d2e3f4", "Bruno", "3 days ago", "Add idempotency: keys & retries"]
        ]
            .map { $0.joined(separator: sep) }
            .joined(separator: "\n") + "\n"

        let commits = GitLogParser.parse(output)
        #expect(commits.count == 2)
        #expect(commits[0].hash == "9f3c2a1e4b7d8c6f0a1b2c3d4e5f60718293a4b5")
        #expect(commits[0].shortHash == "9f3c2a1")
        #expect(commits[0].author == "Ana Souza")
        #expect(commits[0].relativeDate == "2 hours ago")
        #expect(commits[0].subject == "Fix flaky transcript test")
        #expect(commits[1].subject == "Add idempotency: keys & retries")
    }

    @Test func skipsMalformedCommitLines() {
        let good = ["abc", "abc1", "Ana", "now", "Subject"].joined(separator: sep)
        let output = "\(good)\nnot a commit line\n\(sep)\(sep)\(sep)\(sep)\n"
        let commits = GitLogParser.parse(output)
        #expect(commits.map(\.subject) == ["Subject"])
    }

    @Test func parsesBranchesWithTracking() {
        let output = [
            ["main", "3 hours ago", "[ahead 2, behind 1]"],
            ["feature/x", "2 days ago", ""],
            ["old-spike", "3 weeks ago", "[gone]"],
            ["release/1.2", "5 days ago", "[ahead 3]"],
            ["behind-only", "1 day ago", "[behind 4]"]
        ]
            .map { $0.joined(separator: "\t") }
            .joined(separator: "\n") + "\n"

        let branches = GitBranchParser.parse(output)
        #expect(branches.map(\.name) == ["main", "feature/x", "old-spike", "release/1.2", "behind-only"])
        #expect(branches[0].ahead == 2 && branches[0].behind == 1)
        #expect(branches[1].ahead == 0 && branches[1].behind == 0 && !branches[1].upstreamIsGone)
        #expect(branches[2].upstreamIsGone)
        #expect(branches[3].ahead == 3 && branches[3].behind == 0)
        #expect(branches[4].behind == 4)
    }

    @Test func keepsOnlyTheMostRecentBranches() {
        let output = (1...12).map { "branch-\($0)\tnow\t" }.joined(separator: "\n")
        let branches = GitBranchParser.parse(output)
        #expect(branches.count == GitCommands.branchLimit)
        #expect(branches.first?.name == "branch-1")
    }

    @Test func parsesGitHubPullRequests() throws {
        let json = """
        [
          {
            "author": {"id": "U_1", "is_bot": false, "login": "ana-souza", "name": "Ana Souza"},
            "headRefName": "feature/login",
            "isDraft": false,
            "number": 142,
            "reviewDecision": "APPROVED",
            "title": "Add login screen",
            "url": "https://github.com/acme/app/pull/142"
          },
          {
            "author": {"id": "U_2", "is_bot": false, "login": "bruno", "name": ""},
            "headRefName": "wip/cache",
            "isDraft": true,
            "number": 151,
            "reviewDecision": "",
            "title": "Cache the feed",
            "url": "https://github.com/acme/app/pull/151"
          },
          {
            "author": null,
            "headRefName": "fix/crash",
            "isDraft": false,
            "number": 160,
            "reviewDecision": null,
            "title": "Fix crash on resume",
            "url": "https://github.com/acme/app/pull/160"
          }
        ]
        """
        let pulls = try GitHubPullRequestParser.parse(Data(json.utf8))
        #expect(pulls.count == 3)
        #expect(pulls[0].number == 142)
        #expect(pulls[0].headBranch == "feature/login")
        #expect(pulls[0].authorLogin == "ana-souza")
        #expect(pulls[0].reviewDecision == .approved)
        #expect(!pulls[0].isDraft)
        #expect(pulls[1].isDraft)
        #expect(pulls[1].reviewDecision == nil)
        #expect(pulls[2].authorLogin == nil)
        #expect(pulls[2].reviewDecision == nil)
    }

    @Test func treatsEmptyOutputAsNoPullRequests() throws {
        #expect(try GitHubPullRequestParser.parse(Data("[]".utf8)).isEmpty)
        #expect(try GitHubPullRequestParser.parse(Data()).isEmpty)
    }

    @Test func rejectsGarbagePullRequestOutput() {
        #expect(throws: (any Error).self) {
            try GitHubPullRequestParser.parse(Data("no repository found".utf8))
        }
    }
}

@Suite("Git repository list and tools")
struct GitSupportTests {
    @Test func dedupesRepositoryRoots() {
        let roots = GitRepoCatalog.unique([
            "/Users/dev/work/app/",
            "/Users/dev/work/app",
            "",
            "  /Users/dev/work/lib  ",
            "/Users/dev/work/app/../lib"
        ])
        #expect(roots == ["/Users/dev/work/app", "/Users/dev/work/lib"])
    }

    @Test func listsGitHubCLICandidatesInPriorityOrder() {
        let home = URL(fileURLWithPath: "/Users/dev", isDirectory: true)
        let paths = GitHubCLILocator.candidates(path: "/usr/bin:/opt/tools/bin:/usr/bin", home: home).map(\.path)
        #expect(paths == [
            "/Users/dev/.local/bin/gh",
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
            "/opt/tools/bin/gh"
        ])
    }

    @Test func findsAnExecutableGitHubCLIInTheUserBin() throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let bin = scratch.url.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = bin.appendingPathComponent("gh")
        FileManager.default.createFile(atPath: gh.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let located = GitHubCLILocator.locate(path: "", home: scratch.url)
        #expect(located?.path == gh.path)
    }
}

@Suite("Git client on a real repository", .serialized)
struct GitClientTests {
    private func git(_ arguments: [String], in directory: URL) async throws {
        let identity = ["-c", "user.name=TaskBar Tests", "-c", "user.email=tests@example.com", "-c", "init.defaultBranch=main"]
        let output = try await ProcessRunner.run(
            executable: GitCommands.gitExecutable,
            arguments: identity + arguments,
            input: Data(),
            workingDirectory: directory,
            timeout: 30
        )
        #expect(output.status == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    @Test func readsStatusCommitsAndBranchesOfARepository() async throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let repo = scratch.url.appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        try await git(["init", "-q"], in: repo)
        try "hello\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "a.txt"], in: repo)
        try await git(["commit", "-q", "-m", "First commit"], in: repo)
        // One tracked edit and one untracked file.
        try "changed\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let client = GitClient(gitHubCLI: nil)
        let root = try #require(await client.repositoryRoot(containing: repo.path))
        #expect(URL(fileURLWithPath: root).lastPathComponent == "sample")

        let snapshot = await client.snapshot(of: root)
        let status = try #require(snapshot.status)
        #expect(status.branch == "main")
        #expect(status.modifiedCount == 1)
        #expect(status.untrackedCount == 1)
        #expect(status.totalChanges == 2)
        #expect(snapshot.commits.map(\.subject) == ["First commit"])
        #expect(snapshot.branches.map(\.name) == ["main"])
        #expect(snapshot.pullRequests.isEmpty)
    }

    @Test func returnsNoRootOutsideARepository() async throws {
        let scratch = try TemporaryDirectory()
        defer { scratch.remove() }
        let client = GitClient(gitHubCLI: nil)
        #expect(await client.repositoryRoot(containing: scratch.url.path) == nil)
    }
}
