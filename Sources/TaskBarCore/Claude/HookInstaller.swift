import Foundation

public enum HookInstallerError: LocalizedError, Equatable {
    case malformedSettings

    public var errorDescription: String? {
        switch self {
        case .malformedSettings:
            "Claude Code's settings.json is not a JSON object, so it was left untouched."
        }
    }
}

/// Installs and removes the Claude Code hooks that notify TaskBar instantly.
///
/// The JSON transformations are pure functions over the decoded settings so they can be
/// tested without touching the real `~/.claude/settings.json`. Existing hooks are preserved.
public enum HookInstaller {
    /// Substring that identifies hook commands owned by TaskBar.
    public static let marker = "taskbar-hook.sh"

    public struct HookSpec: Equatable, Sendable {
        public let event: String
        /// Lite hooks forward only the session ID; their payloads can be very large.
        public let isLite: Bool
    }

    public static let specs: [HookSpec] = [
        HookSpec(event: "SessionStart", isLite: false),
        HookSpec(event: "SessionEnd", isLite: false),
        HookSpec(event: "UserPromptSubmit", isLite: true),
        HookSpec(event: "PermissionRequest", isLite: false),
        HookSpec(event: "PermissionDenied", isLite: true),
        HookSpec(event: "PostToolUse", isLite: true),
        HookSpec(event: "PostToolUseFailure", isLite: true),
        HookSpec(event: "Notification", isLite: false),
        HookSpec(event: "Stop", isLite: true)
    ]

    /// The relay script. It only writes a small file into a spool directory watched by the
    /// app: no network, no daemon, and it exits immediately when the app is not running.
    public static let scriptContents = #"""
    #!/bin/sh
    # TaskBar hook relay for Claude Code - https://github.com/thomazzi98/task-bar
    #
    # Forwards a hook payload (JSON on stdin) to the TaskBar menu bar app by dropping a file
    # into a spool directory the app watches. It never blocks Claude Code and always exits 0.
    #
    # Usage: taskbar-hook.sh              forward the payload (capped at 64 KB)
    #        taskbar-hook.sh lite <Event> forward only the session ID

    spool="${TASKBAR_DATA_DIR:-$HOME/Library/Application Support/TaskBar}/hook-events"

    # The app writes its process ID here while it runs. No app, nothing to do.
    [ -f "$spool/.pid" ] || exit 0
    read -r app_pid < "$spool/.pid" || exit 0
    kill -0 "$app_pid" 2>/dev/null || exit 0

    name="$(date +%s)-$$"
    tmp="$spool/.$name.tmp"

    if [ "$1" = "lite" ]; then
      session_id="$({ head -c 4096; cat >/dev/null; } |
        LC_ALL=C sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' |
        head -n 1)"
      [ -n "$session_id" ] || exit 0
      printf '{"hook_event_name":"%s","session_id":"%s"}\n' "$2" "$session_id" > "$tmp" || exit 0
    else
      { head -c 65536; cat >/dev/null; } > "$tmp" || exit 0
    fi

    mv "$tmp" "$spool/$name.json" 2>/dev/null
    exit 0
    """# + "\n"

    // MARK: Pure settings transformations

    /// The shell command registered for `spec`. Uses `$HOME` so the settings stay portable.
    public static func command(for spec: HookSpec, scriptPath: String) -> String {
        let quoted = "\"\(portablePath(scriptPath))\""
        return spec.isLite ? "\(quoted) lite \(spec.event)" : quoted
    }

    public static func isInstalled(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return specs.allSatisfy { spec in
            groups(hooks[spec.event]).contains(where: containsTaskBarHook)
        }
    }

    /// Returns `settings` with the TaskBar hooks added. Idempotent; other hooks are untouched.
    public static func merging(into settings: [String: Any], scriptPath: String) -> [String: Any] {
        var settings = removing(from: settings)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for spec in specs {
            var eventGroups = groups(hooks[spec.event])
            let handler: [String: Any] = [
                "type": "command",
                "command": command(for: spec, scriptPath: scriptPath),
                "async": true
            ]
            eventGroups.append(["hooks": [handler]])
            hooks[spec.event] = eventGroups
        }
        settings["hooks"] = hooks
        return settings
    }

    /// Returns `settings` without any TaskBar hook, dropping containers left empty.
    public static func removing(from settings: [String: Any]) -> [String: Any] {
        guard var hooks = settings["hooks"] as? [String: Any] else { return settings }
        var settings = settings

        for (event, value) in hooks {
            guard value is [Any] else { continue }
            let remaining = groups(value).compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let kept = handlers.filter { !isTaskBarHandler($0) }
                guard !kept.isEmpty else { return nil }
                var group = group
                group["hooks"] = kept
                return group
            }
            if remaining.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = remaining
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        return settings
    }

    // MARK: File operations

    public static func isInstalled(paths: AppPaths) -> Bool {
        guard let settings = try? readSettings(at: paths.claudeSettingsFile) else { return false }
        return isInstalled(in: settings) && FileManager.default.fileExists(atPath: paths.hookScript.path)
    }

    /// Writes the relay script and registers the hooks. Returns the settings backup, if one
    /// was made.
    @discardableResult
    public static func install(paths: AppPaths) throws -> URL? {
        // Read first: unreadable settings must abort before anything is written.
        let settings = try readSettings(at: paths.claudeSettingsFile)
        let merged = merging(into: settings, scriptPath: paths.hookScript.path)
        try writeScript(to: paths.hookScript)
        return try writeSettings(merged, to: paths.claudeSettingsFile)
    }

    /// Unregisters the hooks and deletes the relay script.
    @discardableResult
    public static func uninstall(paths: AppPaths) throws -> URL? {
        let settings = try readSettings(at: paths.claudeSettingsFile)
        let backup = try writeSettings(removing(from: settings), to: paths.claudeSettingsFile)
        try? FileManager.default.removeItem(at: paths.hookScript)
        return backup
    }

    public static func writeScript(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(scriptContents.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\n") }) { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError.malformedSettings
        }
        return settings
    }

    /// Writes the settings atomically, keeping the original file's permissions and leaving a
    /// timestamped backup of the previous contents next to it.
    private static func writeSettings(_ settings: [String: Any], to url: URL) throws -> URL? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var backup: URL?
        var permissions: Any?
        if fileManager.fileExists(atPath: url.path) {
            permissions = try fileManager.attributesOfItem(atPath: url.path)[.posixPermissions]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let destination = url.deletingLastPathComponent()
                .appendingPathComponent("settings.json.taskbar-backup-\(formatter.string(from: Date()))")
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: url, to: destination)
            backup = destination
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return backup
    }

    // MARK: Helpers

    private static func portablePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "$HOME" + path.dropFirst(home.count) : path
    }

    private static func groups(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func containsTaskBarHook(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]])?.contains(where: isTaskBarHandler) ?? false
    }

    private static func isTaskBarHandler(_ handler: [String: Any]) -> Bool {
        (handler["command"] as? String)?.contains(marker) ?? false
    }
}
