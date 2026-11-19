import Darwin
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
        var order: [String] = []

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
                    order.append(id)
                }
            default:
                continue
            }
        }

        return order
            .compactMap { ports[$0] }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
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

/// Runs lsof off the main thread. Kept apart from the parser so the parser stays pure.
public enum ListeningPortScanner {
    /// Lists the listening TCP ports. Returns `nil` when lsof cannot run or has to be stopped
    /// for taking longer than `timeout`, so the caller can keep the last good list.
    public static func scan(timeout: TimeInterval = 3) async -> [ListeningPort]? {
        await Task.detached(priority: .utility) { () -> [ListeningPort]? in
            guard let output = runLsof(timeout: timeout) else { return nil }
            return ListeningPortParser.parse(String(decoding: output, as: UTF8.self))
        }.value
    }

    private static func runLsof(timeout: TimeInterval) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcnLu"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Output is drained before waiting, so a long listing cannot fill the pipe and stall.
        let processID = process.processIdentifier
        let watchdog = DispatchWorkItem { kill(processID, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        // Exit status 1 only means nothing matched. A signal means lsof was cut short.
        return process.terminationReason == .uncaughtSignal ? nil : output
    }
}

/// Decides which listening processes may be stopped from the System tab.
public enum PortStopRules {
    public enum Block: Equatable, Sendable {
        /// PID 1 and below, or TaskBar itself.
        case protectedProcess
        /// Owned by another login, so the kernel would refuse the signal anyway.
        case ownedByOtherUser(String)
    }

    public static func block(for port: ListeningPort, currentUserID: UInt32, ownPID: Int32) -> Block? {
        if port.pid <= 1 || port.pid == ownPID { return .protectedProcess }
        if port.userID != currentUserID { return .ownedByOtherUser(port.user) }
        return nil
    }
}
