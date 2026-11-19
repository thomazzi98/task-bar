/// What a port is typically used for.
public struct PortService: Equatable, Sendable {
    public var label: String
    /// Data stores get a database mark in the UI and count under the "Databases" filter.
    public var isDatabase: Bool
    /// HTTP-like services get an "Open" button that launches them in the browser.
    public var isWebLike: Bool

    public init(label: String, isDatabase: Bool = false, isWebLike: Bool = false) {
        self.label = label
        self.isDatabase = isDatabase
        self.isWebLike = isWebLike
    }
}

/// Identifies a listening port from its number, or failing that from the command that owns it.
public enum KnownPorts {
    private static let byPort: [UInt16: PortService] = [
        3000: PortService(label: "Dev server", isWebLike: true),
        3001: PortService(label: "Dev server", isWebLike: true),
        4200: PortService(label: "Angular", isWebLike: true),
        5173: PortService(label: "Vite", isWebLike: true),
        5174: PortService(label: "Vite", isWebLike: true),
        8000: PortService(label: "HTTP", isWebLike: true),
        8080: PortService(label: "HTTP", isWebLike: true),
        9229: PortService(label: "Node inspector"),
        5432: PortService(label: "PostgreSQL", isDatabase: true),
        3306: PortService(label: "MySQL", isDatabase: true),
        27017: PortService(label: "MongoDB", isDatabase: true),
        6379: PortService(label: "Redis", isDatabase: true),
        11211: PortService(label: "Memcached", isDatabase: true),
        9200: PortService(label: "Elasticsearch", isDatabase: true, isWebLike: true),
        5672: PortService(label: "RabbitMQ"),
        2375: PortService(label: "Docker API"),
        2376: PortService(label: "Docker API")
    ]

    /// Matched by prefix against the lowercased command name, so `python3.12` counts as Python.
    private static let byCommand: [(prefix: String, service: PortService)] = [
        ("postgres", PortService(label: "PostgreSQL", isDatabase: true)),
        ("mysqld", PortService(label: "MySQL", isDatabase: true)),
        ("mongod", PortService(label: "MongoDB", isDatabase: true)),
        ("redis-server", PortService(label: "Redis", isDatabase: true)),
        ("memcached", PortService(label: "Memcached", isDatabase: true)),
        ("node", PortService(label: "Node.js", isWebLike: true)),
        ("python", PortService(label: "Python", isWebLike: true)),
        ("ruby", PortService(label: "Ruby", isWebLike: true)),
        ("java", PortService(label: "Java", isWebLike: true)),
        ("docker", PortService(label: "Docker")),
        ("com.docker", PortService(label: "Docker"))
    ]

    public static func service(for port: UInt16, command: String) -> PortService? {
        if let known = byPort[port] { return known }
        let name = command.lowercased()
        return byCommand.first { name.hasPrefix($0.prefix) }?.service
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
