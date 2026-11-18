import Foundation

public enum DockerError: LocalizedError, Equatable {
    /// No Docker engine is listening on any known socket.
    case unavailable
    case requestFailed(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Docker is not running."
        case .requestFailed(let status, let message):
            message.isEmpty ? "Docker returned HTTP \(status)." : message
        }
    }
}

public enum DockerAction: String, Sendable {
    case start, stop, restart
}

/// Talks to the local Docker Engine API over its Unix socket. Works with Docker Desktop,
/// OrbStack, Colima and Rancher Desktop without the `docker` CLI being installed.
public actor DockerClient {
    private let candidateSockets: [String]
    private var activeSocket: String?
    private var previousStats: [String: DockerStatsSample] = [:]

    public init(candidateSockets: [String] = DockerClient.defaultSocketPaths()) {
        self.candidateSockets = candidateSockets
    }

    /// Well-known socket locations, honouring `DOCKER_HOST` when it names a Unix socket.
    public static func defaultSocketPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        var paths: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            paths.append(String(host.dropFirst("unix://".count)))
        }
        paths += [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.rd/docker.sock"
        ]
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public func containers(includeStopped: Bool) throws -> [DockerContainer] {
        let response = try request("GET", "/containers/json?all=\(includeStopped)")
        let containers = try JSONDecoder().decode([DockerContainer].self, from: response.body)
        let liveIDs = Set(containers.map(\.id))
        previousStats = previousStats.filter { liveIDs.contains($0.key) }
        return DockerMath.sorted(containers)
    }

    /// CPU and memory for the given containers. Containers whose stats cannot be read are
    /// simply left out.
    public func usage(for containerIDs: [String]) -> [String: DockerUsage] {
        var result: [String: DockerUsage] = [:]
        for containerID in containerIDs {
            guard let response = try? request("GET", "/containers/\(containerID)/stats?stream=false&one-shot=true"),
                  let sample = try? JSONDecoder().decode(DockerStatsSample.self, from: response.body)
            else { continue }

            let cpuPercent = previousStats[containerID].flatMap {
                DockerMath.cpuPercent(previous: $0, current: sample)
            }
            previousStats[containerID] = sample
            result[containerID] = DockerUsage(
                cpuPercent: cpuPercent,
                memoryBytes: DockerMath.memoryBytes(sample),
                memoryLimitBytes: sample.memoryLimit
            )
        }
        return result
    }

    public func perform(_ action: DockerAction, on containerID: String) throws {
        // Stopping waits for the container's grace period, so allow plenty of time.
        _ = try request("POST", "/containers/\(containerID)/\(action.rawValue)", timeout: 40)
    }

    // MARK: Private

    private func request(_ method: String, _ path: String, timeout: TimeInterval = 5) throws -> HTTPResponse {
        let socketPath = try resolveSocket()
        let response: HTTPResponse
        do {
            response = try UnixSocketHTTP.send(socketPath: socketPath, method: method, path: path, timeout: timeout)
        } catch {
            // The engine went away; look for it again on the next call.
            activeSocket = nil
            throw DockerError.unavailable
        }

        // 304 means "already in that state" for start/stop, which is fine.
        guard response.isSuccess || response.statusCode == 304 else {
            let payload = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            throw DockerError.requestFailed(status: response.statusCode, message: payload?["message"] as? String ?? "")
        }
        return response
    }

    private func resolveSocket() throws -> String {
        if let activeSocket { return activeSocket }
        let fileManager = FileManager.default
        guard let socket = candidateSockets.first(where: {
            fileManager.fileExists(atPath: $0) && UnixSocketHTTP.canConnect(to: $0)
        }) else { throw DockerError.unavailable }
        activeSocket = socket
        return socket
    }
}
