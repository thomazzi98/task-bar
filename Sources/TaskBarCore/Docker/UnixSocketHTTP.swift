import Darwin
import Foundation

public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

public enum HTTPResponseParserError: Error, Equatable {
    case malformed
}

/// A minimal HTTP/1.x response parser: status line, headers, and a plain or chunked body.
public enum HTTPResponseParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineTerminator = Data("\r\n".utf8)

    public static func parse(_ data: Data) throws -> HTTPResponse {
        guard let headerEnd = data.range(of: headerTerminator) else {
            throw HTTPResponseParserError.malformed
        }
        let headerText = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerText.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw HTTPResponseParserError.malformed
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data(data[headerEnd.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(body)
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    static func decodeChunked(_ data: Data) throws -> Data {
        var result = Data()
        var index = data.startIndex

        while index < data.endIndex {
            guard let lineEnd = data.range(of: lineTerminator, in: index..<data.endIndex) else {
                throw HTTPResponseParserError.malformed
            }
            // A chunk header is the size in hex, optionally followed by `;extensions`.
            let sizeField = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeField, radix: 16), size >= 0 else {
                throw HTTPResponseParserError.malformed
            }
            if size == 0 { break }

            let chunkStart = lineEnd.upperBound
            let chunkEnd = chunkStart + size
            guard chunkEnd <= data.endIndex else { throw HTTPResponseParserError.malformed }
            result.append(data[chunkStart..<chunkEnd])
            index = min(chunkEnd + lineTerminator.count, data.endIndex)
        }
        return result
    }
}

public enum UnixSocketError: Error, Equatable {
    case pathTooLong
    case socketFailed(Int32)
    case connectionFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
}

/// Sends a single HTTP request over a Unix domain socket and reads the whole response.
///
/// `URLSession` cannot talk to Unix sockets, and this is all the Docker Engine API needs, so
/// a few dozen lines of POSIX sockets replace a networking dependency. Calls block; run them
/// off the main thread.
public enum UnixSocketHTTP {
    public static func send(
        socketPath: String,
        method: String,
        path: String,
        timeout: TimeInterval = 5
    ) throws -> HTTPResponse {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketError.socketFailed(errno) }
        defer { close(descriptor) }

        configure(descriptor, timeout: timeout)
        try connect(descriptor, to: socketPath)

        // HTTP/1.0 makes the server close the connection after one un-chunked response.
        let request = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nAccept: application/json\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        try writeAll(Array(request.utf8), to: descriptor)
        return try HTTPResponseParser.parse(try readAll(from: descriptor))
    }

    /// Whether something is accepting connections on the socket.
    public static func canConnect(to socketPath: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        configure(descriptor, timeout: 1)
        return (try? connect(descriptor, to: socketPath)) != nil
    }

    // MARK: Private

    private static func configure(_ descriptor: Int32, timeout: TimeInterval) {
        // A peer that hangs up must surface as an error, not kill the app with SIGPIPE.
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var interval = timeval(tv_sec: Int(timeout.rounded(.up)), tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &interval, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &interval, size)
    }

    private static func connect(_ descriptor: Int32, to socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // Leave room for the terminating NUL already present in the zeroed struct.
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw UnixSocketError.connectionFailed(errno) }
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written > 0 {
                offset += written
            } else if errno != EINTR {
                throw UnixSocketError.writeFailed(errno)
            }
        }
    }

    private static func readAll(from descriptor: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                response.append(buffer, count: count)
            } else if count == 0 {
                return response
            } else if errno != EINTR {
                throw UnixSocketError.readFailed(errno)
            }
        }
    }
}
