import AppKit
import TaskBarCore

/// Brings the window that hosts a Claude Code session to the front.
///
/// The strategy depends on where the session runs:
/// - Terminal and iTerm2: select the exact tab, matched by its tty.
/// - Editors (VS Code, Cursor, ...): re-open the workspace folder, which focuses its window.
/// - Anything else: activate the owning app.
@MainActor
enum WindowFocuser {
    enum Outcome: Equatable {
        case focused(appName: String)
        case notFound
    }

    @discardableResult
    static func focus(_ session: AgentSession, paths: AppPaths) -> Outcome {
        guard let host = hostApplication(for: session.pid) else { return .notFound }
        let name = host.localizedName ?? "the app"

        switch host.bundleIdentifier {
        case "com.apple.Terminal":
            if let tty = ProcessInspector.details(of: session.pid)?.ttyPath, selectTerminalTab(tty: tty) {
                return .focused(appName: name)
            }
        case "com.googlecode.iterm2":
            if let tty = ProcessInspector.details(of: session.pid)?.ttyPath, selectITermSession(tty: tty) {
                return .focused(appName: name)
            }
        default:
            if let folder = openWorkspaceFolder(containing: session.cwd, paths: paths),
               let appURL = host.bundleURL {
                NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                return .focused(appName: name)
            }
        }

        host.activate(options: [.activateAllWindows])
        return .focused(appName: name)
    }

    /// The nearest ancestor of `pid` that is a regular, Dock-visible application.
    static func hostApplication(for pid: Int32) -> NSRunningApplication? {
        for candidate in [pid] + ProcessInspector.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    // MARK: Editors

    /// Editors with the Claude Code extension publish lock files listing their open workspace
    /// folders. Re-opening one of those folders focuses the existing window; opening any
    /// other folder would spawn a new window, so nothing is opened unless a lock file matches.
    private static func openWorkspaceFolder(containing cwd: String, paths: AppPaths) -> URL? {
        let lockFiles = (try? FileManager.default.contentsOfDirectory(
            at: paths.claudeIDEDirectory,
            includingPropertiesForKeys: nil
        )) ?? []

        let folders = lockFiles
            .filter { $0.pathExtension == "lock" }
            .compactMap { url -> [String]? in
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pid = (object["pid"] as? NSNumber)?.int32Value, ProcessInspector.isAlive(pid)
                else { return nil }
                return object["workspaceFolders"] as? [String]
            }
            .flatMap { $0 }

        return folders
            .filter { cwd == $0 || cwd.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: Terminals

    private static func selectTerminalTab(tty: String) -> Bool {
        runAppleScript("""
        tell application "Terminal"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    if tty of theTab is "\(tty)" then
                        set selected of theTab to true
                        set index of theWindow to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """)
    }

    private static func selectITermSession(tty: String) -> Bool {
        runAppleScript("""
        tell application "iTerm2"
            repeat with theWindow in windows
                repeat with theTab in tabs of theWindow
                    repeat with theSession in sessions of theTab
                        if tty of theSession is "\(tty)" then
                            select theWindow
                            tell theTab to select
                            tell theSession to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """)
    }

    /// Runs a script that returns a boolean. The first call asks the user for permission to
    /// control the target app; a refusal simply yields `false`.
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }
}
