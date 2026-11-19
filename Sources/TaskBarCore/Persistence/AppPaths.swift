import Foundation

/// Every file-system location the app touches, in one place. Tests build an instance rooted
/// in a temporary directory; the app uses `AppPaths.live()`.
public struct AppPaths: Sendable, Equatable {
    /// `~/Library/Application Support/TaskBar`
    public let supportDirectory: URL
    /// `~/.claude`
    public let claudeDirectory: URL

    public init(supportDirectory: URL, claudeDirectory: URL) {
        self.supportDirectory = supportDirectory
        self.claudeDirectory = claudeDirectory
    }

    /// Environment variable that relocates TaskBar's own data, e.g. to try a build against
    /// a scratch folder. The hook script honours the same variable.
    public static let dataDirectoryVariable = "TASKBAR_DATA_DIR"
    /// Environment variable that points at Claude Code's data, overriding its own
    /// `CLAUDE_CONFIG_DIR` and the default `~/.claude`.
    public static let claudeDirectoryVariable = "TASKBAR_CLAUDE_DIR"

    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        func directory(_ variable: String) -> URL? {
            guard let path = environment[variable], !path.isEmpty else { return nil }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return AppPaths(
            supportDirectory: directory(dataDirectoryVariable)
                ?? applicationSupport.appendingPathComponent("TaskBar", isDirectory: true),
            claudeDirectory: directory(claudeDirectoryVariable)
                ?? directory("CLAUDE_CONFIG_DIR")
                ?? home.appendingPathComponent(".claude", isDirectory: true)
        )
    }

    // MARK: TaskBar data

    public var tasksFile: URL { supportDirectory.appendingPathComponent("tasks.json") }
    public var notesFile: URL { supportDirectory.appendingPathComponent("notes.json") }
    public var clipboardFile: URL { supportDirectory.appendingPathComponent("clipboard.json") }
    public var linksFile: URL { supportDirectory.appendingPathComponent("links.json") }

    /// Spool directory the Claude Code hook script drops event files into.
    public var hookEventsDirectory: URL {
        supportDirectory.appendingPathComponent("hook-events", isDirectory: true)
    }

    /// Holds the app's process ID while it runs, so the hook script can no-op otherwise.
    public var hookPIDFile: URL { hookEventsDirectory.appendingPathComponent(".pid") }

    public var hookScript: URL {
        supportDirectory.appendingPathComponent("hooks/taskbar-hook.sh")
    }

    // MARK: Claude Code data (read-only, except settings when the user installs hooks)

    public var claudeSessionsDirectory: URL {
        claudeDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    public var claudeProjectsDirectory: URL {
        claudeDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    public var claudeIDEDirectory: URL {
        claudeDirectory.appendingPathComponent("ide", isDirectory: true)
    }

    public var claudeSettingsFile: URL { claudeDirectory.appendingPathComponent("settings.json") }
}
