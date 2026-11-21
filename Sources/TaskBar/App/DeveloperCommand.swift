import Foundation
import TaskBarCore

/// Headless commands for checking the app's building blocks from a terminal, without the UI.
///
/// They run the same code paths as the app, which makes them handy for bug reports and for
/// verifying a build:
///
///     TaskBar.app/Contents/MacOS/TaskBar --agents
///
/// This type parses the arguments and dispatches; `DeveloperReports` does the work and prints.
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
    case renderLive(directory: URL)
    case ports
    case drives
    case devices
    case tokenUsage(period: UsagePeriod)
    case git(path: String)
    case ask(question: String)

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
      --render-live <directory>        Render the live-data screens from this Mac to PNG files.
                                       Run through `open -W -n TaskBar.app --args ...` so macOS
                                       asks for Bluetooth on behalf of the app, not the terminal.
      --ports                          List the TCP ports that are listening, with their owners.
      --drives                         List the mounted volumes with their space and flags.
      --devices                        List connected peripherals and their battery levels.
      --usage [today|7d|30d|all]      Summarise Claude Code token usage (default 7d).
      --git <path>                     Summarise the Git repository at that path.
      --ask "<question>"               Ask the Mac assistant once: print the snapshot it would get,
                                       then its answer and proposed actions. Never runs an action.
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
        case "--render-live":
            guard let path = value(after: "--render-live") else { return nil }
            self = .renderLive(directory: URL(fileURLWithPath: path, isDirectory: true))
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
        case "--ask":
            guard let question = value(after: "--ask"), !question.isEmpty else { return nil }
            self = .ask(question: question)
        default:
            // Unknown flags (macOS passes some of its own) start the app normally.
            return nil
        }
    }

    /// Runs the command and returns the process exit code.
    func run() async -> Int32 {
        do {
            switch self {
            case .help: print(Self.usage)
            case .agents: try await DeveloperReports.agents()
            case .system: await DeveloperReports.system()
            case .calendar: DeveloperReports.calendar()
            case .printHookScript: DeveloperReports.hookScript()
            case .printHookSettings: try DeveloperReports.hookSettings()
            case .installHooks: try DeveloperReports.installHooks()
            case .uninstallHooks: try DeveloperReports.uninstallHooks()
            case .polish(let style, let preference): try await DeveloperReports.polish(style: style, preference: preference)
            case .transcribe(let file, let locale): try await DeveloperReports.transcribe(file: file, locale: locale)
            case .renderSnapshots(let directory): try DeveloperReports.renderSnapshots(directory: directory)
            case .renderLive(let directory): try await DeveloperReports.renderLive(directory: directory)
            case .ports: await DeveloperReports.ports()
            case .drives: DeveloperReports.drives()
            case .devices: DeveloperReports.devices()
            case .tokenUsage(let period): await DeveloperReports.usage(period: period)
            case .git(let path): try await DeveloperReports.git(path: path)
            case .ask(let question): try await DeveloperReports.ask(question: question)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
