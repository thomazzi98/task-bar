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
}
