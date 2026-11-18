import Foundation

public struct DockerPort: Decodable, Equatable, Sendable {
    public var privatePort: Int
    public var publicPort: Int?
    public var type: String?

    private enum CodingKeys: String, CodingKey {
        case privatePort = "PrivatePort"
        case publicPort = "PublicPort"
        case type = "Type"
    }

    public init(privatePort: Int, publicPort: Int? = nil, type: String? = nil) {
        self.privatePort = privatePort
        self.publicPort = publicPort
        self.type = type
    }
}

/// A container as returned by `GET /containers/json`.
public struct DockerContainer: Identifiable, Decodable, Equatable, Sendable {
    public var id: String
    public var names: [String]
    public var image: String
    /// `running`, `exited`, `paused`, `restarting`, ...
    public var state: String
    /// Human-readable status, e.g. `Up 3 hours`.
    public var status: String
    public var ports: [DockerPort]
    public var labels: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
        case labels = "Labels"
    }

    public init(
        id: String,
        names: [String],
        image: String,
        state: String,
        status: String,
        ports: [DockerPort] = [],
        labels: [String: String] = [:]
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.status = status
        self.ports = ports
        self.labels = labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        names = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        ports = try container.decodeIfPresent([DockerPort].self, forKey: .ports) ?? []
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }

    /// Container name without Docker's leading slash.
    public var name: String {
        let raw = names.first ?? String(id.prefix(12))
        return raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
    }

    public var composeProject: String? {
        labels["com.docker.compose.project"]
    }

    public var isRunning: Bool { state == "running" }

    /// Host ports the container publishes, without duplicates (IPv4 and IPv6 list twice).
    public var publishedPorts: [Int] {
        Array(Set(ports.compactMap(\.publicPort))).sorted()
    }
}

/// The counters needed from `GET /containers/{id}/stats`.
public struct DockerStatsSample: Decodable, Equatable, Sendable {
    public var cpuTotal: UInt64
    public var systemCPU: UInt64
    public var onlineCPUs: Int
    public var memoryUsage: UInt64
    public var memoryInactiveFile: UInt64
    public var memoryLimit: UInt64

    public init(
        cpuTotal: UInt64,
        systemCPU: UInt64,
        onlineCPUs: Int,
        memoryUsage: UInt64,
        memoryInactiveFile: UInt64,
        memoryLimit: UInt64
    ) {
        self.cpuTotal = cpuTotal
        self.systemCPU = systemCPU
        self.onlineCPUs = onlineCPUs
        self.memoryUsage = memoryUsage
        self.memoryInactiveFile = memoryInactiveFile
        self.memoryLimit = memoryLimit
    }

    private enum RootKeys: String, CodingKey {
        case cpuStats = "cpu_stats"
        case memoryStats = "memory_stats"
    }

    private enum CPUKeys: String, CodingKey {
        case cpuUsage = "cpu_usage"
        case systemCPUUsage = "system_cpu_usage"
        case onlineCPUs = "online_cpus"
    }

    private enum CPUUsageKeys: String, CodingKey {
        case totalUsage = "total_usage"
    }

    private enum MemoryKeys: String, CodingKey {
        case usage, limit, stats
    }

    private enum MemoryDetailKeys: String, CodingKey {
        case inactiveFile = "inactive_file"
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)

        let cpu = try? root.nestedContainer(keyedBy: CPUKeys.self, forKey: .cpuStats)
        let cpuUsage = try? cpu?.nestedContainer(keyedBy: CPUUsageKeys.self, forKey: .cpuUsage)
        cpuTotal = (try? cpuUsage?.decodeIfPresent(UInt64.self, forKey: .totalUsage)) ?? 0
        systemCPU = (try? cpu?.decodeIfPresent(UInt64.self, forKey: .systemCPUUsage)) ?? 0
        onlineCPUs = (try? cpu?.decodeIfPresent(Int.self, forKey: .onlineCPUs)) ?? 0

        let memory = try? root.nestedContainer(keyedBy: MemoryKeys.self, forKey: .memoryStats)
        let detail = try? memory?.nestedContainer(keyedBy: MemoryDetailKeys.self, forKey: .stats)
        memoryUsage = (try? memory?.decodeIfPresent(UInt64.self, forKey: .usage)) ?? 0
        memoryLimit = (try? memory?.decodeIfPresent(UInt64.self, forKey: .limit)) ?? 0
        memoryInactiveFile = (try? detail?.decodeIfPresent(UInt64.self, forKey: .inactiveFile)) ?? 0
    }
}

public struct DockerUsage: Equatable, Sendable {
    /// Percentage of one core. `nil` until two samples exist to compare.
    public var cpuPercent: Double?
    public var memoryBytes: UInt64
    public var memoryLimitBytes: UInt64

    public init(cpuPercent: Double?, memoryBytes: UInt64, memoryLimitBytes: UInt64) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.memoryLimitBytes = memoryLimitBytes
    }
}

public enum DockerMath {
    /// Same formula the `docker stats` command uses.
    public static func cpuPercent(previous: DockerStatsSample, current: DockerStatsSample) -> Double? {
        guard current.cpuTotal >= previous.cpuTotal, current.systemCPU > previous.systemCPU else { return nil }
        let containerDelta = Double(current.cpuTotal - previous.cpuTotal)
        let systemDelta = Double(current.systemCPU - previous.systemCPU)
        return containerDelta / systemDelta * Double(max(current.onlineCPUs, 1)) * 100
    }

    /// Working-set memory: total usage minus reclaimable file cache, as `docker stats` shows.
    public static func memoryBytes(_ sample: DockerStatsSample) -> UInt64 {
        sample.memoryUsage >= sample.memoryInactiveFile
            ? sample.memoryUsage - sample.memoryInactiveFile
            : sample.memoryUsage
    }

    /// Running containers first, then grouped by Compose project and sorted by name.
    public static func sorted(_ containers: [DockerContainer]) -> [DockerContainer] {
        containers.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let leftProject = lhs.composeProject ?? ""
            let rightProject = rhs.composeProject ?? ""
            if leftProject != rightProject { return leftProject < rightProject }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
