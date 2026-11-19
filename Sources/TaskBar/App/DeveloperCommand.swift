import Foundation
import TaskBarCore

/// Headless commands for checking the app's building blocks from a terminal, without the UI.
///
/// They run the same code paths as the app, which makes them handy for bug reports and for
/// verifying a build:
///
///     TaskBar.app/Contents/MacOS/TaskBar --agents
@MainActor
enum DeveloperCommand {
    case help
    case agents
    case system
    case calendar
    case printHookScript
    case printHookSettings
    case installHooks
    case uninstallHooks
    case polish(style: PolishStyle, preference: PolisherPreference)
    case transcribe(file: URL, locale: Locale)
    case renderSnapshots(directory: URL)
    case ports
    case drives
    case devices
    case tokenUsage(period: UsagePeriod)
    case git(path: String)

    static let usage = """
    TaskBar — menu bar productivity app. Run without arguments to start the app.

    Self-test commands:
      --agents                         List the Claude Code sessions TaskBar can see.
      --system                         Print one reading of CPU, memory, processes and Docker.
      --calendar                       Show calendar access and the next week's events.
      --install-hooks                  Install the Claude Code hooks (same as the Settings button).
      --uninstall-hooks                Remove the Claude Code hooks.
      --print-hook-script              Print the hook relay script.
      --print-hook-settings            Print the settings.json fragment that registers the hooks.
      --polish <note|prompt>           Rewrite text from standard input with "Tidy up".
          [--engine auto|apple|claude]
      --transcribe <audio-file>        Transcribe an audio file with the dictation engine.
          [--locale <bcp47>]
      --render-snapshots <directory>   Render every screen with sample data to PNG files.
      --ports                          List the TCP ports that are listening, with their owners.
      --drives                         List the mounted volumes with their space and flags.
      --devices                        List connected peripherals and their battery levels.
      --usage [today|7d|30d|all]      Summarise Claude Code token usage (default 7d).
      --git <path>                     Summarise the Git repository at that path.
      --help                           Show this message.
    """

    init?(arguments: [String]) {
        let options = Array(arguments.dropFirst())
        guard let name = options.first(where: { $0.hasPrefix("--") }) else { return nil }

        func value(after flag: String) -> String? {
            guard let index = options.firstIndex(of: flag), options.indices.contains(index + 1) else { return nil }
            return options[index + 1]
        }

        switch name {
        case "--help":
            self = .help
        case "--agents":
            self = .agents
        case "--system":
            self = .system
        case "--calendar":
            self = .calendar
        case "--print-hook-script":
            self = .printHookScript
        case "--print-hook-settings":
            self = .printHookSettings
        case "--install-hooks":
            self = .installHooks
        case "--uninstall-hooks":
            self = .uninstallHooks
        case "--polish":
            let style = PolishStyle(rawValue: value(after: "--polish") ?? "") ?? .note
            let preference: PolisherPreference = switch value(after: "--engine") {
            case "apple": .appleIntelligence
            case "claude": .claude
            default: .automatic
            }
            self = .polish(style: style, preference: preference)
        case "--transcribe":
            guard let path = value(after: "--transcribe") else { return nil }
            let locale = value(after: "--locale").map(Locale.init(identifier:)) ?? .current
            self = .transcribe(file: URL(fileURLWithPath: path), locale: locale)
        case "--render-snapshots":
            guard let path = value(after: "--render-snapshots") else { return nil }
            self = .renderSnapshots(directory: URL(fileURLWithPath: path, isDirectory: true))
        case "--ports":
            self = .ports
        case "--drives":
            self = .drives
        case "--devices":
            self = .devices
        case "--usage":
            let period: UsagePeriod = switch value(after: "--usage") {
            case "today": .today
            case "30d": .month
            case "all": .all
            default: .week
            }
            self = .tokenUsage(period: period)
        case "--git":
            guard let path = value(after: "--git") else { return nil }
            self = .git(path: path)
        default:
            // Unknown flags (macOS passes some of its own) start the app normally.
            return nil
        }
    }

    /// Runs the command and returns the process exit code.
    func run() async -> Int32 {
        do {
            switch self {
            case .help:
                print(Self.usage)
            case .agents:
                try await printAgents()
            case .system:
                await printSystem()
            case .calendar:
                printCalendar()
            case .printHookScript:
                print(HookInstaller.scriptContents, terminator: "")
            case .printHookSettings:
                try printHookSettings()
            case .installHooks:
                let paths = AppPaths.live()
                let backup = try HookInstaller.install(paths: paths)
                print("Hooks installed in \(paths.claudeSettingsFile.path)")
                if let backup { print("Previous settings saved as \(backup.path)") }
            case .uninstallHooks:
                let paths = AppPaths.live()
                try HookInstaller.uninstall(paths: paths)
                print("Hooks removed from \(paths.claudeSettingsFile.path)")
            case .polish(let style, let preference):
                try await polish(style: style, preference: preference)
            case .transcribe(let file, let locale):
                try await transcribe(file: file, locale: locale)
            case .renderSnapshots(let directory):
                let files = try SnapshotRenderer.renderAll(into: directory)
                files.forEach { print($0.path) }
            case .ports:
                await printPorts()
            case .drives:
                printDrives()
            case .devices:
                await printDevices()
            case .tokenUsage(let period):
                await printUsage(period: period)
            case .git(let path):
                try await printGit(path: path)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: Commands

    private func printAgents() async throws {
        let paths = AppPaths.live()
        let scanner = AgentScanner(paths: paths)
        let clock = ContinuousClock()
        var sessions: [AgentSession] = []
        let coldScan = await clock.measure { sessions = await scanner.scan() }
        let warmScan = await clock.measure { _ = await scanner.scan() }
        print("hooks installed: \(HookInstaller.isInstalled(paths: paths))")
        print("sessions: \(sessions.count)   first scan: \(coldScan.formatted(.units(allowed: [.milliseconds])))   repeat scan: \(warmScan.formatted(.units(allowed: [.milliseconds])))")
        for session in sessions {
            print("")
            print("  \(session.projectName)  [\(session.status.label)]  pid \(session.pid)")
            print("    title:    \(session.displayTitle)")
            if let detail = session.statusDetail { print("    detail:   \(detail)") }
            if let prompt = session.lastPrompt {
                print("    prompt:   \(prompt.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(90) ?? "")")
            }
            print("    entries:  \(session.entries.count)   branch: \(session.gitBranch ?? "-")   entrypoint: \(session.entrypoint ?? "-")")
            print("    host app: \(WindowFocuser.hostApplication(for: session.pid)?.localizedName ?? "not found")")
        }
    }

    private func printSystem() async {
        let metrics = SystemMetricsSampler()
        let processes = ProcessSampler()
        _ = await metrics.sample()
        _ = await processes.sample()
        try? await Task.sleep(for: .seconds(1))
        let snapshot = await metrics.sample()
        let usages = await processes.sample()

        if let cpu = snapshot.cpu {
            print("cpu:      \(Formatting.percent(cpu.overall)) across \(cpu.perCore.count) cores")
        }
        if let memory = snapshot.memory {
            print("memory:   \(Formatting.bytes(memory.usedBytes)) of \(Formatting.bytes(memory.totalBytes)), pressure \(memory.pressure.label)")
        }
        if let disk = snapshot.disk {
            print("disk:     \(Formatting.bytes(disk.availableBytes)) free of \(Formatting.bytes(disk.totalBytes))")
        }
        if let battery = snapshot.battery {
            print("battery:  \(battery.percent)%\(battery.isCharging ? " (charging)" : "")")
        }
        if let network = snapshot.network {
            print("network:  down \(Formatting.rate(network.bytesInPerSecond)), up \(Formatting.rate(network.bytesOutPerSecond))")
        }
        print("uptime:   \(Formatting.uptime(snapshot.uptime)), thermal \(snapshot.thermal.label)")

        print("\ntop processes by CPU:")
        for usage in usages.sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(5) {
            let name = ProcessInspector.fullName(of: usage.pid) ?? usage.name
            print(String(format: "  %5.1f%%  %9@  %@ (%d)", usage.cpuPercent, Formatting.bytes(usage.memoryBytes), name, usage.pid))
        }

        let docker = DockerClient()
        do {
            let containers = try await docker.containers(includeStopped: true)
            print("\ndocker:   \(containers.count) container(s)")
            for container in containers {
                print("  \(container.isRunning ? "●" : "○") \(container.name)  \(container.image)  \(container.status)")
            }
        } catch {
            print("\ndocker:   \(error.localizedDescription)")
        }
    }

    private func printHookSettings() throws {
        let settings = HookInstaller.merging(into: [:], scriptPath: AppPaths.live().hookScript.path)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    private func printCalendar() {
        let service = CalendarService()
        print("access: \(service.access)")
        guard service.access == .granted else {
            print("Open TaskBar > Calendar and choose Connect Calendar to grant access.")
            return
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let events = service.events(from: Calendar.current.startOfDay(for: now), to: end)
        print("events in the next 7 days: \(events.count)")
        for day in AgendaBuilder.days(from: events, now: now) {
            print("\n  \(day.date.formatted(date: .abbreviated, time: .omitted))")
            for event in day.events {
                let time = event.isAllDay ? "all day" : event.start.formatted(date: .omitted, time: .shortened)
                print("    \(time)  \(event.title)\(event.meetingURL == nil ? "" : "  [video call]")")
            }
        }
    }

    private func polish(style: PolishStyle, preference: PolisherPreference) async throws {
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let resolution = PolisherProvider.resolve(preference: preference)
        guard let polisher = resolution.polisher else {
            throw TextPolishError.engineUnavailable(resolution.unavailableReason ?? "No model is available.")
        }
        FileHandle.standardError.write(Data("engine: \(polisher.name)\n".utf8))
        print(try await polisher.polish(input, style: style))
    }

    private func transcribe(file: URL, locale: Locale) async throws {
        guard #available(macOS 26.0, *) else {
            throw DictationError.engineFailure("File transcription needs macOS 26 or later.")
        }
        print(try await AnalyzerPipeline.transcribe(fileAt: file, locale: locale))
    }

    private func printPorts() async {
        guard let ports = await ListeningPortScanner.scan() else {
            print("ports: lsof failed or took too long")
            return
        }
        print("port  service  command  PID  local|all")
        for port in ports {
            let service = KnownPorts.service(for: port.port, command: port.command)?.label ?? "-"
            let scope = port.isLoopbackOnly ? "local" : "all"
            print(String(format: "%5d  %@  %@  %d  %@", Int(port.port), service, port.command, port.pid, scope))
        }
        print("ports: \(ports.count)")
    }

    private func printDrives() {
        let volumes = VolumeArrangement.arrange(VolumeProbe.mounted())
        for volume in volumes {
            print(volume.name)
            print("  format:     \(volume.formatName.isEmpty ? "-" : volume.formatName)")
            print("  space:      \(Formatting.bytes(volume.availableBytes)) free of \(Formatting.bytes(volume.totalBytes))")
            print("  removable:  \(volume.isRemovable)   ejectable: \(volume.isEjectable)")
        }
        print("drives: \(volumes.count)")
    }

    private func printDevices() async {
        let registry = PeripheralProbes.registryDevices()
        let bluetooth = PeripheralProbes.bluetoothDevices(timeout: 10)
        let merged = PeripheralMerge.merge(bluetooth ?? [], registry)
        print("registry: \(registry.count)   bluetooth: \(bluetooth.map { "\($0.count)" } ?? "unavailable")")
        for device in merged {
            var levels: [String] = []
            if let level = device.level { levels.append("battery \(level)%") }
            if let left = device.leftLevel { levels.append("left \(left)%") }
            if let right = device.rightLevel { levels.append("right \(right)%") }
            if let caseLevel = device.caseLevel { levels.append("case \(caseLevel)%") }
            if device.isCharging { levels.append("charging") }
            print("\(device.name)  [\(device.kind.rawValue)]  \(levels.joined(separator: ", "))")
        }
        print("devices: \(merged.count)")
    }

    private func printUsage(period: UsagePeriod) async {
        let clock = ContinuousClock()
        var report: UsageReport?
        let elapsed = await clock.measure {
            report = await UsageScanner(paths: AppPaths.live()).report(for: period)
        }
        guard let report else { return }

        let totals = report.totals
        let usage = totals.usage
        let cost = totals.cost.map { String(format: "$%.2f", $0) } ?? "n/a"
        let cache = totals.cacheHitRate.map { Formatting.percent($0) } ?? "n/a"
        print("period:    \(period.title)   messages: \(totals.messages)   bytes read: \(Formatting.bytes(UInt64(report.bytesRead)))")
        print("tokens:    \(usage.total) (input \(usage.input), output \(usage.output), cache write \(usage.cacheWrite), cache read \(usage.cacheRead))")
        print("est. cost: \(cost)   cache hit: \(cache)")
        // Plain seconds with an explicit unit: a pt-BR locale would print 18.418 ms as "18 ms".
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "scan took: %.2f s", seconds))

        print("\nby model:")
        for row in report.byModel {
            print("  \(row.name)  tokens \(row.usage.total)  messages \(row.messages)  cost \(row.cost.map { String(format: "$%.2f", $0) } ?? "n/a")")
        }
        print("\ntop projects:")
        for row in report.byProject.prefix(5) {
            print("  \(row.name)  tokens \(row.usage.total)  messages \(row.messages)")
        }
        print("\ntop sessions:")
        for row in report.topSessions.prefix(5) {
            print("  \(row.sessionID)  \(row.project)  tokens \(row.usage.total)  messages \(row.messages)")
        }
    }

    private func printGit(path: String) async throws {
        let client = GitClient(gitHubCLI: GitHubCLILocator.locate())
        guard let root = await client.repositoryRoot(containing: path) else {
            throw NotAGitRepository(path: path)
        }
        let snapshot = await client.snapshot(of: root)

        print("repository: \(snapshot.root)")
        if let status = snapshot.status {
            print("branch:     \(status.branch ?? "detached")   upstream: \(status.upstream ?? "-")")
            print("ahead/behind: \(status.ahead)/\(status.behind)")
            print("changes:    \(status.totalChanges) total, \(status.stagedCount) staged, \(status.modifiedCount) modified, \(status.untrackedCount) untracked, \(status.conflictedCount) conflicted")
        } else {
            print("status:     unavailable")
        }

        print("\nlast commits:")
        for commit in snapshot.commits.prefix(5) {
            print("  \(commit.shortHash)  \(commit.relativeDate)  \(commit.author)  \(commit.subject)")
        }

        print("\nbranches: \(snapshot.branches.count)")
        for branch in snapshot.branches {
            let gone = branch.upstreamIsGone ? "  upstream gone" : ""
            print("  \(branch.name)  ahead \(branch.ahead) behind \(branch.behind)  \(branch.relativeDate)\(gone)")
        }

        if client.gitHubCLI == nil {
            print("\npull requests: gh not installed")
        } else {
            print("\npull requests: \(snapshot.pullRequests.count)")
            for pullRequest in snapshot.pullRequests {
                let draft = pullRequest.isDraft ? "  draft" : ""
                print("  #\(pullRequest.number)  \(pullRequest.headBranch)  \(pullRequest.title)\(draft)")
            }
        }
    }

    private struct NotAGitRepository: LocalizedError {
        let path: String
        var errorDescription: String? { "not inside a git repository: \(path)" }
    }
}
