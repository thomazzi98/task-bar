import Foundation

/// A Claude Code hook payload relayed by the hook script.
public struct HookEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case sessionStart
        case sessionEnd
        case promptSubmitted
        case permissionRequested
        case permissionDenied
        case toolFinished
        case stopped
        case notification(NotificationKind)
        case other(String)
    }

    public enum NotificationKind: Equatable, Sendable {
        /// A permission dialog has been waiting for a few seconds.
        case permissionPrompt
        /// Claude finished a while ago and nothing was typed since.
        case idlePrompt
        /// Claude or an MCP server is asking the user for input.
        case needsInput
        case other
    }

    public var kind: Kind
    public var sessionID: String
    public var cwd: String?
    public var transcriptPath: String?
    /// Human-readable description of what is being asked, when the payload carries one.
    public var detail: String?
    public var receivedAt: Date

    public init(
        kind: Kind,
        sessionID: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        detail: String? = nil,
        receivedAt: Date = Date()
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.detail = detail
        self.receivedAt = receivedAt
    }

    /// Parses a spooled payload. Large payloads are truncated by the hook script and are no
    /// longer valid JSON, so a byte-level scan recovers the essential fields in that case.
    public static func parse(_ data: Data, receivedAt: Date = Date()) -> HookEvent? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parse(object, receivedAt: receivedAt)
        }
        let text = String(decoding: data, as: UTF8.self)
        guard let sessionID = scanString("session_id", in: text),
              let name = scanString("hook_event_name", in: text)
        else { return nil }
        var fields: [String: Any] = ["session_id": sessionID, "hook_event_name": name]
        for key in ["cwd", "transcript_path", "tool_name", "message", "notification_type"] {
            if let value = scanString(key, in: text) {
                fields[key] = value
            }
        }
        return parse(fields, receivedAt: receivedAt)
    }

    private static func parse(_ object: [String: Any], receivedAt: Date) -> HookEvent? {
        guard let sessionID = object["session_id"] as? String, !sessionID.isEmpty,
              let name = object["hook_event_name"] as? String
        else { return nil }

        let message = object["message"] as? String
        let kind: Kind
        var detail: String?

        switch name {
        case "SessionStart": kind = .sessionStart
        case "SessionEnd": kind = .sessionEnd
        case "UserPromptSubmit": kind = .promptSubmitted
        case "PermissionDenied": kind = .permissionDenied
        case "PostToolUse", "PostToolUseFailure": kind = .toolFinished
        case "Stop": kind = .stopped
        case "PermissionRequest":
            kind = .permissionRequested
            detail = toolDetail(from: object)
        case "Notification":
            let notification = notificationKind(type: object["notification_type"] as? String, message: message)
            kind = .notification(notification)
            detail = message
        default:
            kind = .other(name)
        }

        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            cwd: object["cwd"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            detail: detail,
            receivedAt: receivedAt
        )
    }

    private static func toolDetail(from object: [String: Any]) -> String? {
        guard let tool = object["tool_name"] as? String else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let summary = TranscriptParser.toolSummary(name: tool, input: input)
        return summary.isEmpty ? tool : "\(tool): \(summary)"
    }

    private static func notificationKind(type: String?, message: String?) -> NotificationKind {
        switch type {
        case "permission_prompt": return .permissionPrompt
        case "idle_prompt": return .idlePrompt
        case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": return .needsInput
        case .some: return .other
        case .none: break
        }
        // Older payloads carry no type, only a sentence.
        let text = message?.lowercased() ?? ""
        if text.contains("permission") { return .permissionPrompt }
        if text.contains("waiting for your input") { return .idlePrompt }
        return .other
    }

    /// Finds `"key":"value"` in possibly truncated JSON text.
    private static func scanString(_ key: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index] == " " || text[index] == ":" {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)

        var value = ""
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                value.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return value
            } else {
                value.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// What the hook stream last told us a session is doing.
public enum HookPhase: Equatable, Sendable {
    case working(since: Date)
    case awaitingApproval(detail: String?, since: Date)
    case awaitingInput(detail: String?, since: Date)
    case stopped(since: Date)

    public var since: Date {
        switch self {
        case .working(let since), .stopped(let since): since
        case .awaitingApproval(_, let since), .awaitingInput(_, let since): since
        }
    }
}

public enum HookPhaseReducer {
    /// Folds one event into the phase of its session. Events that say nothing about activity
    /// leave the phase unchanged.
    public static func reduce(_ phase: HookPhase?, with event: HookEvent) -> HookPhase? {
        let now = event.receivedAt
        switch event.kind {
        case .promptSubmitted, .toolFinished, .permissionDenied:
            return .working(since: now)
        case .permissionRequested:
            return .awaitingApproval(detail: event.detail, since: now)
        case .stopped:
            return .stopped(since: now)
        case .notification(.permissionPrompt):
            // The instant `PermissionRequest` event usually arrived first and has better detail.
            if case .awaitingApproval = phase { return phase }
            return .awaitingApproval(detail: event.detail, since: now)
        case .notification(.needsInput):
            return .awaitingInput(detail: event.detail, since: now)
        case .notification(.idlePrompt):
            if case .stopped = phase { return phase }
            return .stopped(since: now)
        case .sessionStart, .sessionEnd:
            return nil
        case .notification(.other), .other:
            return phase
        }
    }
}

/// Reads and removes the event files the hook script drops into the spool directory.
public struct HookEventSpool: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Creates the spool and records the app's process ID so the hook script knows the app is
    /// running. Leftovers from a previous run are discarded.
    public func open(processID: Int32) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = drain()
        try Data("\(processID)\n".utf8).write(to: directory.appendingPathComponent(".pid"), options: .atomic)
    }

    /// Removes the liveness marker; the hook script becomes a no-op until the next launch.
    public func close() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".pid"))
    }

    /// Returns pending events in arrival order and deletes their files.
    public func drain(now: Date = Date()) -> [HookEvent] {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url -> HookEvent? in
                defer { try? fileManager.removeItem(at: url) }
                guard let data = try? Data(contentsOf: url) else { return nil }
                return HookEvent.parse(data, receivedAt: now)
            }
    }
}
