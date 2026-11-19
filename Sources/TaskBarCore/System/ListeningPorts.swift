import Foundation

/// A TCP port in the LISTEN state, with the process that owns it.
public struct ListeningPort: Identifiable, Equatable, Sendable {
    public var pid: Int32
    public var command: String
    /// Login name of the owner, as lsof reports it.
    public var user: String
    public var userID: UInt32
    public var port: UInt16
    /// The address shown for the port. A wildcard (`*`) wins over a loopback address.
    public var address: String
    /// `true` only when every socket on this port is bound to loopback.
    public var isLoopbackOnly: Bool

    public init(
        pid: Int32,
        command: String,
        user: String,
        userID: UInt32,
        port: UInt16,
        address: String,
        isLoopbackOnly: Bool
    ) {
        self.pid = pid
        self.command = command
        self.user = user
        self.userID = userID
        self.port = port
        self.address = address
        self.isLoopbackOnly = isLoopbackOnly
    }

    /// One row per process and port, so an IPv4 and an IPv6 socket of the same server stay together.
    public var id: String { "\(pid):\(port)" }

    /// What the port is used for, from the port number first and then the command name.
    public var service: PortService? {
        KnownPorts.service(for: port, command: command)
    }
}

/// Parses the field output of `lsof -nP -iTCP -sTCP:LISTEN -F pcnLu`.
///
/// Each line starts with a one-letter field id: `p` opens a process, `c`, `u` and `L` describe
/// it, `n` names a socket (`*:3000`, `127.0.0.1:5432`, `[::1]:6379`), and `f` opens a file
/// descriptor, which this parser does not need.
public enum ListeningPortParser {
    public static func parse(_ output: String) -> [ListeningPort] {
        var ports: [String: ListeningPort] = [:]

        var pid: Int32?
        var command = ""
        var user = ""
        var userID: UInt32 = 0

        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
                command = ""
                user = ""
                userID = 0
            case "c":
                command = value
            case "L":
                user = value
            case "u":
                userID = UInt32(value) ?? 0
            case "n":
                guard let pid, let endpoint = Endpoint(name: value) else { continue }
                let id = "\(pid):\(endpoint.port)"
                if var existing = ports[id] {
                    existing.isLoopbackOnly = existing.isLoopbackOnly && endpoint.isLoopback
                    if !Endpoint.isWildcard(existing.address), Endpoint.isWildcard(endpoint.address) {
                        existing.address = endpoint.address
                    }
                    ports[id] = existing
                } else {
                    ports[id] = ListeningPort(
                        pid: pid,
                        command: command,
                        user: user,
                        userID: userID,
                        port: endpoint.port,
                        address: endpoint.address,
                        isLoopbackOnly: endpoint.isLoopback
                    )
                }
            default:
                continue
            }
        }

        return ports.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// The `address:port` part of an `n` field.
    private struct Endpoint {
        let address: String
        let port: UInt16

        init?(name: String) {
            // Connected sockets read `local->remote`. Only the local end matters here.
            let local = name.components(separatedBy: "->").first ?? name
            guard let colon = local.lastIndex(of: ":"),
                  let port = UInt16(local[local.index(after: colon)...]), port > 0
            else { return nil }
            var address = String(local[..<colon])
            if address.hasPrefix("["), address.hasSuffix("]") {
                address = String(address.dropFirst().dropLast())
            }
            guard !address.isEmpty else { return nil }
            self.address = address
            self.port = port
        }

        var isLoopback: Bool {
            address == "localhost"
                || address.hasPrefix("127.")
                || address == "::1"
                || address.hasPrefix("::ffff:127.")
        }

        static func isWildcard(_ address: String) -> Bool {
            address == "*" || address == "0.0.0.0" || address == "::"
        }
    }
}

/// Runs lsof and parses its listing.
public enum ListeningPortScanner {
    /// Lists the listening TCP ports. Returns `nil` when lsof cannot run or is stopped for taking
    /// longer than `timeout`, so the caller can keep the last good list.
    public static func scan(timeout: TimeInterval = 3) async -> [ListeningPort]? {
        guard let output = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnLu"],
            timeout: timeout
        ), !output.timedOut else { return nil }
        // Status 1 only means nothing matched, which parses to an empty list. Any other status failed.
        guard output.status == 0 || output.status == 1 else { return nil }
        return ListeningPortParser.parse(String(decoding: output.standardOutput, as: UTF8.self))
    }
}

/// The segments of the Ports list.
public enum PortFilter: String, CaseIterable, Identifiable, Sendable {
    case all, development, databases

    public var id: String { rawValue }

    public func includes(_ service: PortService?) -> Bool {
        switch self {
        case .all: true
        case .development: service?.isDatabase != true
        case .databases: service?.isDatabase == true
        }
    }
}

/// Decides which listening processes may be stopped from the System tab.
public enum PortStopRules {
    public enum Block: Equatable, Sendable {
        /// A system process or TaskBar itself, by the shared `ProcessMath.isProtected` rule.
        case protectedProcess
        /// Owned by another login, so the kernel would refuse the signal anyway.
        case ownedByOtherUser(String)
    }

    public static func block(for port: ListeningPort, currentUserID: UInt32, ownPID: Int32) -> Block? {
        guard ProcessMath.isProtected(
            pid: port.pid,
            userID: port.userID,
            name: port.command,
            currentUserID: currentUserID,
            ownPID: ownPID
        ) else { return nil }
        return port.userID != currentUserID ? .ownedByOtherUser(port.user) : .protectedProcess
    }
}
