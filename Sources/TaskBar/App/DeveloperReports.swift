import Foundation
import TaskBarCore

/// The output of each headless developer command. `DeveloperCommand` parses the arguments and
/// calls one of these; each prints what the command reports, using the same code as the app.
@MainActor
enum DeveloperReports {
    static func agents() async throws {
        let paths = AppPaths.live()
        let scanner = AgentScanner(paths: paths)
        let coldStart = ContinuousClock.now
        let sessions = await scanner.scan()
        let coldScan = ContinuousClock.now - coldStart
        let warmStart = ContinuousClock.now
        _ = await scanner.scan()
        let warmScan = ContinuousClock.now - warmStart

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

    static func system() async {
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

    static func hookScript() {
        print(HookInstaller.scriptContents, terminator: "")
    }

    static func hookSettings() throws {
        let settings = HookInstaller.merging(into: [:], scriptPath: AppPaths.live().hookScript.path)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    }

    static func installHooks() throws {
        let paths = AppPaths.live()
        let backup = try HookInstaller.install(paths: paths)
        print("Hooks installed in \(paths.claudeSettingsFile.path)")
        if let backup { print("Previous settings saved as \(backup.path)") }
    }

    static func uninstallHooks() throws {
        let paths = AppPaths.live()
        try HookInstaller.uninstall(paths: paths)
        print("Hooks removed from \(paths.claudeSettingsFile.path)")
    }

    static func calendar() {
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

    static func polish(style: PolishStyle, preference: PolisherPreference) async throws {
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let resolution = PolisherProvider.resolve(preference: preference)
        guard let polisher = resolution.polisher else {
            throw TextPolishError.engineUnavailable(resolution.unavailableReason ?? "No model is available.")
        }
        FileHandle.standardError.write(Data("engine: \(polisher.name)\n".utf8))
        print(try await polisher.polish(input, style: style))
    }

    static func transcribe(file: URL, locale: Locale) async throws {
        guard #available(macOS 26.0, *) else {
            throw DictationError.engineFailure("File transcription needs macOS 26 or later.")
        }
        print(try await AnalyzerPipeline.transcribe(fileAt: file, locale: locale))
    }

    static func renderSnapshots(directory: URL) throws {
        let files = try SnapshotRenderer.renderAll(into: directory)
        files.forEach { print($0.path) }
    }

    static func renderLive(directory: URL) async throws {
        let files = try await SnapshotRenderer.renderLive(into: directory)
        files.forEach { print($0.path) }
    }

    static func ports() async {
        guard let ports = await ListeningPortScanner.scan() else {
            print("ports: lsof failed or took too long")
            return
        }
        print("port  service  command  PID  local|all")
        for port in ports {
            let service = port.service?.label ?? "-"
            let scope = port.isLoopbackOnly ? "local" : "all"
            print(String(format: "%5d  %@  %@  %d  %@", Int(port.port), service, port.command, port.pid, scope))
        }
        print("ports: \(ports.count)")
    }

    static func drives() {
        let volumes = VolumeArrangement.arrange(VolumeProbe.mounted())
        for volume in volumes {
            print(volume.name)
            print("  format:     \(volume.formatName.isEmpty ? "-" : volume.formatName)")
            print("  space:      \(Formatting.bytes(volume.availableBytes)) free of \(Formatting.bytes(volume.totalBytes))")
            print("  removable:  \(volume.isRemovable)   ejectable: \(volume.isEjectable)")
        }
        print("drives: \(volumes.count)")
    }

    static func devices() {
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

    static func usage(period: UsagePeriod) async {
        let started = ContinuousClock.now
        let report = await UsageScanner(paths: AppPaths.live()).report(for: period)
        let elapsed = ContinuousClock.now - started

        let totals = report.totals
        let usage = totals.usage
        let cache = totals.cacheHitRate.map { Formatting.percent($0) } ?? "n/a"
        print("period:    \(period.title)   messages: \(totals.messages)   bytes read: \(Formatting.bytes(UInt64(report.bytesRead)))")
        print("tokens:    \(usage.total) (input \(usage.input), output \(usage.output), cache write \(usage.cacheWrite), cache read \(usage.cacheRead))")
        print("est. cost: \(Formatting.money(totals.cost))   cache hit: \(cache)")
        // Plain seconds with an explicit unit: a pt-BR locale would print 18.418 ms as "18 ms".
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print(String(format: "scan took: %.2f s", seconds))

        print("\nby model:")
        for row in report.byModel {
            print("  \(row.name)  tokens \(row.usage.total)  messages \(row.messages)  cost \(Formatting.money(row.cost))")
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

    static func git(path: String) async throws {
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


    /// Sends one question to the Mac assistant and prints what it would show. Actions are listed,
    /// never run.
    static func ask(question: String) async throws {
        let report = MachineReport.text(for: await MachineSnapshotCollector().collect())
        print(report)

        guard let executable = ClaudeCLILocator.locate() else {
            throw ClaudeCLI.Failure.failed("Claude Code is not installed on this Mac.")
        }
        let assistant = ClaudeAssistant(executable: executable, projectsDirectory: AppPaths.live().claudeProjectsDirectory)
        let reply = AssistantReply.parse(try await assistant.answer(question: question, report: report, history: []))

        print("\n--- answer ---")
        print(reply.text)
        print("\n--- proposed actions (listed only, not run) ---")
        if reply.actions.isEmpty { print("none") }
        for action in reply.actions { print("- \(action.title)") }
    }

    private struct NotAGitRepository: LocalizedError {

        let path: String
        var errorDescription: String? { "not inside a git repository: \(path)" }
    }
}
