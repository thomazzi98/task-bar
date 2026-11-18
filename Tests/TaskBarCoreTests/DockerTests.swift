import Foundation
import Testing
@testable import TaskBarCore

@Suite("HTTP response parser")
struct HTTPResponseParserTests {
    @Test func parsesAPlainResponse() throws {
        let raw = "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nApi-Version: 1.47\r\n\r\n[{\"Id\":\"abc\"}]"
        let response = try HTTPResponseParser.parse(Data(raw.utf8))
        #expect(response.statusCode == 200)
        #expect(response.isSuccess)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.headers["api-version"] == "1.47")
        #expect(String(decoding: response.body, as: UTF8.self) == "[{\"Id\":\"abc\"}]")
    }

    @Test func parsesAnEmptyBody() throws {
        let response = try HTTPResponseParser.parse(Data("HTTP/1.1 204 No Content\r\nServer: Docker\r\n\r\n".utf8))
        #expect(response.statusCode == 204)
        #expect(response.body.isEmpty)
    }

    @Test func decodesChunkedBodies() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n"
            + "7;ext=1\r\n, world\r\n"
            + "0\r\n\r\n"
        let response = try HTTPResponseParser.parse(Data(raw.utf8))
        #expect(String(decoding: response.body, as: UTF8.self) == "hello, world")
    }

    @Test func reportsErrorStatuses() throws {
        let raw = "HTTP/1.1 404 Not Found\r\n\r\n{\"message\":\"No such container: xyz\"}"
        let response = try HTTPResponseParser.parse(Data(raw.utf8))
        #expect(response.statusCode == 404)
        #expect(!response.isSuccess)
    }

    @Test func rejectsMalformedResponses() {
        #expect(throws: HTTPResponseParserError.malformed) {
            try HTTPResponseParser.parse(Data("definitely not http".utf8))
        }
        #expect(throws: HTTPResponseParserError.malformed) {
            try HTTPResponseParser.parse(Data("NOPE 200 OK\r\n\r\n".utf8))
        }
        #expect(throws: HTTPResponseParserError.malformed) {
            // Declares a 10-byte chunk but supplies 3.
            try HTTPResponseParser.parse(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nA\r\nabc".utf8))
        }
    }
}

@Suite("Docker models")
struct DockerModelTests {
    private let containersJSON = """
    [
      {
        "Id": "8dfafdbc3a40",
        "Names": ["/shop-api-1"],
        "Image": "shop/api:latest",
        "State": "running",
        "Status": "Up 3 hours",
        "Ports": [
          {"IP": "0.0.0.0", "PrivatePort": 8080, "PublicPort": 8080, "Type": "tcp"},
          {"IP": "::", "PrivatePort": 8080, "PublicPort": 8080, "Type": "tcp"},
          {"PrivatePort": 9229, "Type": "tcp"}
        ],
        "Labels": {"com.docker.compose.project": "shop", "com.docker.compose.service": "api"}
      },
      {
        "Id": "aa11bb22cc33dd44",
        "Names": ["/redis"],
        "Image": "redis:7",
        "State": "exited",
        "Status": "Exited (0) 2 days ago",
        "Ports": [],
        "Labels": {}
      },
      { "Id": "ffeeddccbbaa99887766" }
    ]
    """

    @Test func decodesTheContainerList() throws {
        let containers = try JSONDecoder().decode([DockerContainer].self, from: Data(containersJSON.utf8))
        #expect(containers.count == 3)

        let api = containers[0]
        #expect(api.name == "shop-api-1")
        #expect(api.image == "shop/api:latest")
        #expect(api.isRunning)
        #expect(api.status == "Up 3 hours")
        #expect(api.composeProject == "shop")
        #expect(api.publishedPorts == [8080])

        let redis = containers[1]
        #expect(!redis.isRunning)
        #expect(redis.composeProject == nil)
        #expect(redis.publishedPorts.isEmpty)

        // A record with only an ID still decodes and gets a usable name.
        #expect(containers[2].name == "ffeeddccbbaa")
        #expect(containers[2].state.isEmpty)
    }

    @Test func sortsRunningContainersFirstThenByProjectAndName() {
        func container(_ name: String, running: Bool, project: String? = nil) -> DockerContainer {
            DockerContainer(
                id: name,
                names: ["/\(name)"],
                image: "img",
                state: running ? "running" : "exited",
                status: "",
                labels: project.map { ["com.docker.compose.project": $0] } ?? [:]
            )
        }
        let sorted = DockerMath.sorted([
            container("zeta", running: false),
            container("web", running: true, project: "shop"),
            container("standalone", running: true),
            container("api", running: true, project: "shop"),
            container("db", running: true, project: "blog")
        ])
        #expect(sorted.map(\.name) == ["standalone", "db", "api", "web", "zeta"])
    }

    @Test func decodesStatsAndComputesUsage() throws {
        let statsJSON = """
        {
          "cpu_stats": {
            "cpu_usage": {"total_usage": 4000000000},
            "system_cpu_usage": 200000000000,
            "online_cpus": 8
          },
          "memory_stats": {
            "usage": 314572800,
            "limit": 8589934592,
            "stats": {"inactive_file": 104857600}
          }
        }
        """
        let current = try JSONDecoder().decode(DockerStatsSample.self, from: Data(statsJSON.utf8))
        #expect(current.cpuTotal == 4_000_000_000)
        #expect(current.onlineCPUs == 8)
        #expect(DockerMath.memoryBytes(current) == 209_715_200)

        let previous = DockerStatsSample(
            cpuTotal: 3_000_000_000,
            systemCPU: 190_000_000_000,
            onlineCPUs: 8,
            memoryUsage: 0,
            memoryInactiveFile: 0,
            memoryLimit: 0
        )
        // 1e9 of 10e9 system nanoseconds across 8 CPUs = 80% of one core.
        let percent = try #require(DockerMath.cpuPercent(previous: previous, current: current))
        #expect(abs(percent - 80) < 0.0001)
        #expect(DockerMath.cpuPercent(previous: current, current: current) == nil)
    }

    @Test func toleratesStatsFromStoppedContainers() throws {
        // A stopped container reports empty objects.
        let sample = try JSONDecoder().decode(DockerStatsSample.self, from: Data(#"{"cpu_stats":{},"memory_stats":{}}"#.utf8))
        #expect(sample.cpuTotal == 0)
        #expect(sample.memoryLimit == 0)
        #expect(DockerMath.memoryBytes(sample) == 0)
    }

    @Test func resolvesSocketCandidates() {
        let paths = DockerClient.defaultSocketPaths(
            environment: ["DOCKER_HOST": "unix:///custom/docker.sock"],
            home: "/Users/dev"
        )
        #expect(paths.first == "/custom/docker.sock")
        #expect(paths.contains("/Users/dev/.docker/run/docker.sock"))
        #expect(paths.contains("/Users/dev/.orbstack/run/docker.sock"))
        #expect(paths.contains("/var/run/docker.sock"))

        // A TCP host is not something this client can use, so it is ignored.
        let tcp = DockerClient.defaultSocketPaths(environment: ["DOCKER_HOST": "tcp://10.0.0.5:2375"], home: "/Users/dev")
        #expect(tcp.first == "/Users/dev/.docker/run/docker.sock")
    }

    @Test func reportsUnavailableWhenNoEngineIsListening() async {
        let client = DockerClient(candidateSockets: ["/nonexistent/\(UUID().uuidString).sock"])
        await #expect(throws: DockerError.unavailable) {
            try await client.containers(includeStopped: true)
        }
        #expect(await client.usage(for: ["abc"]).isEmpty)
    }
}

/// Exercises the real socket client against a tiny in-process HTTP server.
@Suite("Unix socket HTTP client")
struct UnixSocketHTTPTests {
    /// Answers every request on a Unix socket with the same canned response until stopped.
    private final class StubServer: @unchecked Sendable {
        let path: String
        private let listener: Int32
        private let thread: Thread

        init(response: String) throws {
            // Unix socket paths are limited to ~100 bytes, so avoid the long temp directory.
            let socketPath = "/tmp/taskbar-test-\(UUID().uuidString.prefix(8)).sock"
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw UnixSocketError.socketFailed(errno) }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(descriptor, 4) == 0 else { throw UnixSocketError.connectionFailed(errno) }

            path = socketPath
            listener = descriptor
            thread = Thread {
                // `accept` fails once `stop()` closes the listener, which ends the loop.
                while true {
                    let client = accept(descriptor, nil, nil)
                    guard client >= 0 else { return }
                    var enabled: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

                    var buffer = [UInt8](repeating: 0, count: 4096)
                    // A probe that connects and hangs up sends nothing and gets nothing back.
                    if read(client, &buffer, buffer.count) > 0 {
                        let payload = Array(response.utf8)
                        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
                    }
                    close(client)
                }
            }
            thread.start()
        }

        func stop() {
            close(listener)
            unlink(path)
        }
    }

    @Test func performsARequestOverAUnixSocket() throws {
        let server = try StubServer(response: "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[{\"Id\":\"abc123\",\"Names\":[\"/web\"],\"State\":\"running\"}]")
        defer { server.stop() }

        #expect(UnixSocketHTTP.canConnect(to: server.path))
        let response = try UnixSocketHTTP.send(socketPath: server.path, method: "GET", path: "/containers/json")
        let containers = try JSONDecoder().decode([DockerContainer].self, from: response.body)
        #expect(response.statusCode == 200)
        #expect(containers.map(\.name) == ["web"])
    }

    @Test func failsCleanlyWhenNothingIsListening() {
        let path = "/tmp/taskbar-missing-\(UUID().uuidString.prefix(8)).sock"
        #expect(!UnixSocketHTTP.canConnect(to: path))
        #expect(throws: UnixSocketError.self) {
            try UnixSocketHTTP.send(socketPath: path, method: "GET", path: "/")
        }
    }

    @Test func rejectsPathsTooLongForASocketAddress() {
        let path = "/tmp/" + String(repeating: "a", count: 200)
        #expect(throws: UnixSocketError.pathTooLong) {
            try UnixSocketHTTP.send(socketPath: path, method: "GET", path: "/")
        }
    }
}
