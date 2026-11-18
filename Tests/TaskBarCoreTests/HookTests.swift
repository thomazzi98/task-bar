import Foundation
import Testing
@testable import TaskBarCore

@Suite("Hook events")
struct HookEventTests {
    @Test func parsesAPermissionRequest() throws {
        let payload = """
        {
          "session_id": "abc123",
          "transcript_path": "/Users/dev/.claude/projects/-work-app/abc123.jsonl",
          "cwd": "/work/app",
          "permission_mode": "default",
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": { "command": "rm -rf node_modules", "description": "Remove node_modules directory" }
        }
        """
        let event = try #require(HookEvent.parse(Data(payload.utf8), receivedAt: referenceDate))
        #expect(event.kind == .permissionRequested)
        #expect(event.sessionID == "abc123")
        #expect(event.cwd == "/work/app")
        #expect(event.transcriptPath == "/Users/dev/.claude/projects/-work-app/abc123.jsonl")
        #expect(event.detail == "Bash: Remove node_modules directory")
        #expect(event.receivedAt == referenceDate)
    }

    @Test func mapsEventNamesToKinds() throws {
        let expectations: [(String, HookEvent.Kind)] = [
            ("SessionStart", .sessionStart),
            ("SessionEnd", .sessionEnd),
            ("UserPromptSubmit", .promptSubmitted),
            ("PermissionDenied", .permissionDenied),
            ("PostToolUse", .toolFinished),
            ("PostToolUseFailure", .toolFinished),
            ("Stop", .stopped),
            ("PreCompact", .other("PreCompact"))
        ]
        for (name, kind) in expectations {
            let payload = #"{"hook_event_name":"\#(name)","session_id":"s1"}"#
            #expect(HookEvent.parse(Data(payload.utf8))?.kind == kind)
        }
    }

    @Test func classifiesNotifications() {
        func kind(type: String?, message: String) -> HookEvent.Kind? {
            var object: [String: Any] = ["hook_event_name": "Notification", "session_id": "s1", "message": message]
            if let type { object["notification_type"] = type }
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
            return HookEvent.parse(data)?.kind
        }

        #expect(kind(type: "permission_prompt", message: "x") == .notification(.permissionPrompt))
        #expect(kind(type: "idle_prompt", message: "x") == .notification(.idlePrompt))
        #expect(kind(type: "elicitation_dialog", message: "x") == .notification(.needsInput))
        #expect(kind(type: "agent_needs_input", message: "x") == .notification(.needsInput))
        #expect(kind(type: "auth_success", message: "x") == .notification(.other))
        // Payloads without a type are classified by their wording.
        #expect(kind(type: nil, message: "Claude needs your permission to use Bash") == .notification(.permissionPrompt))
        #expect(kind(type: nil, message: "Claude is waiting for your input") == .notification(.idlePrompt))
        #expect(kind(type: nil, message: "Something else") == .notification(.other))
    }

    @Test func recoversFieldsFromATruncatedPayload() throws {
        // The hook script caps payloads at 64 KB, which can cut the JSON mid-string.
        let truncated = #"{"session_id":"abc-123","cwd":"/work/my \"app\"","hook_event_name":"PermissionRequest","tool_name":"Write","tool_input":{"file_path":"/x/big.txt","content":"aaaaaaaaaaaaaaaa"#
        let event = try #require(HookEvent.parse(Data(truncated.utf8)))
        #expect(event.kind == .permissionRequested)
        #expect(event.sessionID == "abc-123")
        #expect(event.cwd == #"/work/my "app""#)
        #expect(event.detail == "Write")
    }

    @Test func rejectsPayloadsWithoutASession() {
        #expect(HookEvent.parse(Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(HookEvent.parse(Data(#"{"session_id":"","hook_event_name":"Stop"}"#.utf8)) == nil)
        #expect(HookEvent.parse(Data("not json".utf8)) == nil)
    }

    @Test func reducesEventsIntoPhases() {
        func event(_ kind: HookEvent.Kind, detail: String? = nil, at offset: TimeInterval = 0) -> HookEvent {
            HookEvent(kind: kind, sessionID: "s1", detail: detail, receivedAt: referenceDate.addingTimeInterval(offset))
        }

        var phase = HookPhaseReducer.reduce(nil, with: event(.promptSubmitted))
        #expect(phase == .working(since: referenceDate))

        phase = HookPhaseReducer.reduce(phase, with: event(.permissionRequested, detail: "Bash: ls", at: 1))
        #expect(phase == .awaitingApproval(detail: "Bash: ls", since: referenceDate.addingTimeInterval(1)))

        // The delayed notification must not overwrite the richer, earlier permission event.
        phase = HookPhaseReducer.reduce(phase, with: event(.notification(.permissionPrompt), detail: "generic", at: 7))
        #expect(phase == .awaitingApproval(detail: "Bash: ls", since: referenceDate.addingTimeInterval(1)))

        phase = HookPhaseReducer.reduce(phase, with: event(.toolFinished, at: 9))
        #expect(phase == .working(since: referenceDate.addingTimeInterval(9)))

        phase = HookPhaseReducer.reduce(phase, with: event(.stopped, at: 20))
        #expect(phase == .stopped(since: referenceDate.addingTimeInterval(20)))

        // An idle reminder keeps the original stop time, so "finished" is not re-triggered.
        phase = HookPhaseReducer.reduce(phase, with: event(.notification(.idlePrompt), at: 80))
        #expect(phase == .stopped(since: referenceDate.addingTimeInterval(20)))

        phase = HookPhaseReducer.reduce(phase, with: event(.notification(.needsInput), detail: "Pick one", at: 90))
        #expect(phase == .awaitingInput(detail: "Pick one", since: referenceDate.addingTimeInterval(90)))

        // Unrelated events leave the phase alone.
        #expect(HookPhaseReducer.reduce(phase, with: event(.other("PreCompact"), at: 95)) == phase)
        #expect(HookPhaseReducer.reduce(phase, with: event(.notification(.other), at: 95)) == phase)
    }

    @Test func notificationAloneStartsAnApprovalPhase() {
        let event = HookEvent(kind: .notification(.permissionPrompt), sessionID: "s1", detail: "Needs permission", receivedAt: referenceDate)
        #expect(HookPhaseReducer.reduce(nil, with: event) == .awaitingApproval(detail: "Needs permission", since: referenceDate))
    }
}

@Suite("Hook spool")
struct HookEventSpoolTests {
    @Test func drainsEventsInOrderAndDeletesThem() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let directory = temp.paths.hookEventsDirectory
        let spool = HookEventSpool(directory: directory)
        try spool.open(processID: 4242)

        try Data(#"{"hook_event_name":"Stop","session_id":"second"}"#.utf8)
            .write(to: directory.appendingPathComponent("1700000002-10.json"))
        try Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"first"}"#.utf8)
            .write(to: directory.appendingPathComponent("1700000001-99.json"))
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("1700000003-1.json"))
        try Data("partial".utf8).write(to: directory.appendingPathComponent(".1700000004-1.tmp"))

        let events = spool.drain(now: referenceDate)
        #expect(events.map(\.sessionID) == ["first", "second"])
        #expect(events.map(\.kind) == [.promptSubmitted, .stopped])

        // Everything visible is consumed, including the unreadable file.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(leftovers == [".1700000004-1.tmp", ".pid"])
        #expect(spool.drain().isEmpty)
    }

    @Test func openWritesThePIDAndDiscardsStaleEvents() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let directory = temp.paths.hookEventsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"hook_event_name":"Stop","session_id":"stale"}"#.utf8)
            .write(to: directory.appendingPathComponent("1-1.json"))

        let spool = HookEventSpool(directory: directory)
        try spool.open(processID: 777)
        #expect(try String(contentsOf: temp.paths.hookPIDFile, encoding: .utf8) == "777\n")
        #expect(spool.drain().isEmpty)

        spool.close()
        #expect(!FileManager.default.fileExists(atPath: temp.paths.hookPIDFile.path))
    }
}

@Suite("Hook installer")
struct HookInstallerTests {
    private let scriptPath = "/Users/dev/Library/Application Support/TaskBar/hooks/taskbar-hook.sh"

    /// Settings resembling a real user file that already has unrelated hooks.
    private func existingSettings() -> [String: Any] {
        [
            "model": "opus",
            "permissions": ["allow": ["Bash(git status)"]],
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "bash /opt/gate.sh stop", "timeout": 30]]]
                ],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "bash /opt/gate.sh pre-tool"]]]
                ]
            ]
        ]
    }

    private func commands(for event: String, in settings: [String: Any]) -> [String] {
        let hooks = settings["hooks"] as? [String: Any]
        let groups = hooks?[event] as? [[String: Any]] ?? []
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    @Test func addsEveryHookWhilePreservingExistingOnes() {
        let merged = HookInstaller.merging(into: existingSettings(), scriptPath: scriptPath)

        #expect(merged["model"] as? String == "opus")
        #expect(commands(for: "PreToolUse", in: merged) == ["bash /opt/gate.sh pre-tool"])
        #expect(commands(for: "Stop", in: merged).first == "bash /opt/gate.sh stop")
        #expect(commands(for: "Stop", in: merged).count == 2)

        for spec in HookInstaller.specs {
            let owned = commands(for: spec.event, in: merged).filter { $0.contains(HookInstaller.marker) }
            #expect(owned.count == 1, "expected exactly one TaskBar hook for \(spec.event)")
        }
        #expect(HookInstaller.isInstalled(in: merged))
        #expect(!HookInstaller.isInstalled(in: existingSettings()))
    }

    @Test func registersAsyncCommandHooks() throws {
        let merged = HookInstaller.merging(into: [:], scriptPath: scriptPath)
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let groups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)

        #expect(handler["type"] as? String == "command")
        #expect(handler["async"] as? Bool == true)
        #expect(handler["command"] as? String == "\"\(scriptPath)\"")
    }

    @Test func liteHooksPassTheEventName() {
        let lite = HookInstaller.HookSpec(event: "PostToolUse", isLite: true)
        let full = HookInstaller.HookSpec(event: "Notification", isLite: false)
        #expect(HookInstaller.command(for: lite, scriptPath: "/opt/hook.sh") == "\"/opt/hook.sh\" lite PostToolUse")
        #expect(HookInstaller.command(for: full, scriptPath: "/opt/hook.sh") == "\"/opt/hook.sh\"")
    }

    @Test func usesAPortableHomeRelativePath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let spec = HookInstaller.HookSpec(event: "Stop", isLite: false)
        let command = HookInstaller.command(for: spec, scriptPath: "\(home)/Library/Application Support/TaskBar/hooks/taskbar-hook.sh")
        #expect(command == "\"$HOME/Library/Application Support/TaskBar/hooks/taskbar-hook.sh\"")
    }

    @Test func installingTwiceDoesNotDuplicateHooks() {
        let once = HookInstaller.merging(into: existingSettings(), scriptPath: scriptPath)
        let twice = HookInstaller.merging(into: once, scriptPath: scriptPath)
        #expect(NSDictionary(dictionary: once).isEqual(to: twice))
    }

    @Test func reinstallingReplacesAnOutdatedCommand() {
        var settings = existingSettings()
        settings["hooks"] = ["Stop": [["hooks": [["type": "command", "command": "/old/path/taskbar-hook.sh"]]]]]
        let merged = HookInstaller.merging(into: settings, scriptPath: scriptPath)
        #expect(commands(for: "Stop", in: merged) == ["\"\(scriptPath)\" lite Stop"])
    }

    @Test func removingRestoresTheOriginalSettings() {
        let original = existingSettings()
        let merged = HookInstaller.merging(into: original, scriptPath: scriptPath)
        let restored = HookInstaller.removing(from: merged)
        #expect(NSDictionary(dictionary: restored).isEqual(to: original))
    }

    @Test func removingFromSettingsWithOnlyTaskBarHooksDropsTheHooksKey() {
        let merged = HookInstaller.merging(into: ["model": "opus"], scriptPath: scriptPath)
        let restored = HookInstaller.removing(from: merged)
        #expect(restored["hooks"] == nil)
        #expect(restored["model"] as? String == "opus")
    }

    @Test func installsAndUninstallsOnDisk() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let paths = temp.paths
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        let originalData = try JSONSerialization.data(withJSONObject: existingSettings(), options: [.sortedKeys])
        try originalData.write(to: paths.claudeSettingsFile)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.claudeSettingsFile.path)

        #expect(!HookInstaller.isInstalled(paths: paths))
        let installed = try HookInstaller.install(paths: paths)
        let backup = try #require(installed)

        #expect(HookInstaller.isInstalled(paths: paths))
        #expect(try Data(contentsOf: backup) == originalData)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.taskbar-backup-"))
        // Private settings must stay private after the rewrite.
        let permissions = try fileManager.attributesOfItem(atPath: paths.claudeSettingsFile.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(fileManager.isExecutableFile(atPath: paths.hookScript.path))

        try HookInstaller.uninstall(paths: paths)
        #expect(!HookInstaller.isInstalled(paths: paths))
        #expect(!fileManager.fileExists(atPath: paths.hookScript.path))
        let restored = try HookInstaller.readSettings(at: paths.claudeSettingsFile)
        #expect(NSDictionary(dictionary: restored).isEqual(to: existingSettings()))
    }

    @Test func installsWhenNoSettingsFileExistsYet() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        #expect(try HookInstaller.install(paths: temp.paths) == nil)
        #expect(HookInstaller.isInstalled(paths: temp.paths))
    }

    @Test func refusesToTouchMalformedSettings() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let paths = temp.paths
        try FileManager.default.createDirectory(at: paths.claudeDirectory, withIntermediateDirectories: true)
        try Data("[1, 2, 3]".utf8).write(to: paths.claudeSettingsFile)

        #expect(throws: HookInstallerError.malformedSettings) {
            try HookInstaller.install(paths: paths)
        }
        #expect(try String(contentsOf: paths.claudeSettingsFile, encoding: .utf8) == "[1, 2, 3]")
    }
}

/// Runs the real relay script the way Claude Code would, against a throwaway home directory.
@Suite("Hook relay script")
struct HookRelayScriptTests {
    private struct Sandbox {
        let temp: TemporaryDirectory
        let script: URL
        let spool: HookEventSpool

        init() throws {
            temp = try TemporaryDirectory()
            script = temp.url.appendingPathComponent("taskbar-hook.sh")
            try HookInstaller.writeScript(to: script)
            // The script resolves the spool from $HOME, exactly like the installed copy.
            spool = HookEventSpool(directory: temp.url.appendingPathComponent("Library/Application Support/TaskBar/hook-events"))
        }

        @discardableResult
        func run(arguments: [String] = [], input: String, environment: [String: String] = [:]) throws -> Int32 {
            // The payload comes from a file rather than a pipe: the script may exit without
            // reading it, and writing to a pipe nobody reads would raise SIGPIPE here.
            let inputFile = temp.url.appendingPathComponent("payload-\(UUID().uuidString).json")
            try Data(input.utf8).write(to: inputFile)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path] + arguments
            process.environment = ["HOME": temp.url.path, "PATH": "/usr/bin:/bin"].merging(environment) { _, new in new }
            process.standardInput = try FileHandle(forReadingFrom: inputFile)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    @Test func forwardsTheFullPayload() throws {
        let sandbox = try Sandbox()
        defer { sandbox.temp.remove() }
        try sandbox.spool.open(processID: ownPID)

        let payload = #"{"session_id":"abc","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        #expect(try sandbox.run(input: payload) == 0)

        let events = sandbox.spool.drain()
        #expect(events.count == 1)
        #expect(events.first?.kind == .permissionRequested)
        #expect(events.first?.sessionID == "abc")
        #expect(events.first?.detail == "Bash: ls")
    }

    @Test func liteModeForwardsOnlyTheSessionID() throws {
        let sandbox = try Sandbox()
        defer { sandbox.temp.remove() }
        try sandbox.spool.open(processID: ownPID)

        // A large tool response must not reach the spool.
        let big = String(repeating: "x", count: 200_000)
        let payload = #"{"session_id":"abc-123_x","hook_event_name":"PostToolUse","tool_response":"\#(big)"}"#
        #expect(try sandbox.run(arguments: ["lite", "PostToolUse"], input: payload) == 0)

        let files = try FileManager.default.contentsOfDirectory(at: sandbox.spool.directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"abc-123_x\"}\n")
        #expect(sandbox.spool.drain().first?.kind == .toolFinished)
    }

    @Test func doesNothingWhenTheAppIsNotRunning() throws {
        let sandbox = try Sandbox()
        defer { sandbox.temp.remove() }
        let payload = #"{"session_id":"abc","hook_event_name":"Stop"}"#

        // No spool at all: the app has never been launched.
        #expect(try sandbox.run(input: payload) == 0)
        #expect(!FileManager.default.fileExists(atPath: sandbox.spool.directory.path))

        // Spool left behind by a process that no longer exists.
        try sandbox.spool.open(processID: 2_000_000_000)
        #expect(try sandbox.run(input: payload) == 0)
        #expect(sandbox.spool.drain().isEmpty)
    }

    @Test func followsTheDataDirectoryOverride() throws {
        let sandbox = try Sandbox()
        defer { sandbox.temp.remove() }
        let customData = sandbox.temp.url.appendingPathComponent("custom data")
        let customSpool = HookEventSpool(directory: customData.appendingPathComponent("hook-events"))
        try customSpool.open(processID: ownPID)

        let payload = #"{"session_id":"abc","hook_event_name":"Stop"}"#
        #expect(try sandbox.run(input: payload, environment: ["TASKBAR_DATA_DIR": customData.path]) == 0)
        #expect(customSpool.drain().map(\.kind) == [.stopped])
        #expect(!FileManager.default.fileExists(atPath: sandbox.spool.directory.path))
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let sandbox = try Sandbox()
        defer { sandbox.temp.remove() }
        try sandbox.spool.open(processID: ownPID)
        try sandbox.run(input: #"{"session_id":"abc","hook_event_name":"Stop"}"#)

        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.spool.directory.path)
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}
