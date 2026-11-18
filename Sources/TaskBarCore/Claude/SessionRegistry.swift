import Foundation

/// One live Claude Code process, as advertised in `~/.claude/sessions/<pid>.json`.
///
/// Claude Code maintains these files itself. The format is not a documented public contract,
/// so parsing is deliberately tolerant: only `pid`, `sessionId` and `cwd` are required and
/// every other field is optional.
public struct SessionRecord: Equatable, Sendable {
    public var pid: Int32
    public var sessionID: String
    public var cwd: String
    public var name: String?
    /// `"interactive"` for sessions a person is driving.
    public var kind: String?
    /// Where the session runs, e.g. `"cli"` or `"claude-vscode"`.
    public var entrypoint: String?
    /// `"busy"` or `"idle"` in current versions.
    public var status: String?
    /// Set while the session is blocked on the user, e.g. `"dialog open"` or `"input needed"`.
    public var waitingFor: String?
    public var startedAt: Date?
    public var updatedAt: Date?
    public var statusUpdatedAt: Date?

    public init(
        pid: Int32,
        sessionID: String,
        cwd: String,
        name: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        status: String? = nil,
        waitingFor: String? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil
    ) {
        self.pid = pid
        self.sessionID = sessionID
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.entrypoint = entrypoint
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    public init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value,
              let sessionID = object["sessionId"] as? String, !sessionID.isEmpty,
              let cwd = object["cwd"] as? String
        else { return nil }

        self.init(
            pid: pid,
            sessionID: sessionID,
            cwd: cwd,
            name: Self.nonEmpty(object["name"]),
            kind: Self.nonEmpty(object["kind"]),
            entrypoint: Self.nonEmpty(object["entrypoint"]),
            status: Self.nonEmpty(object["status"]),
            waitingFor: Self.nonEmpty(object["waitingFor"]),
            startedAt: Self.date(fromMilliseconds: object["startedAt"]),
            updatedAt: Self.date(fromMilliseconds: object["updatedAt"]),
            statusUpdatedAt: Self.date(fromMilliseconds: object["statusUpdatedAt"])
        )
    }

    /// Sessions a person is driving. Headless (`claude -p`) and background runs are hidden.
    public var isInteractive: Bool {
        kind == nil || kind == "interactive"
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func date(fromMilliseconds value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

/// Reads the set of live Claude Code sessions from the registry directory.
public struct SessionRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Records whose process is still running. A crashed session leaves its file behind, so
    /// each candidate is checked with `isAlive`.
    public func records(isAlive: (Int32) -> Bool = ProcessInspector.isAlive) -> [SessionRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionRecord? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return SessionRecord(json: data)
            }
            .filter { isAlive($0.pid) }
            .sorted { $0.pid < $1.pid }
    }
}
