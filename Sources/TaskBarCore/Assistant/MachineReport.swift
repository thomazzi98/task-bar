import Foundation

/// Everything the Mac assistant may know about the machine, gathered at one moment.
public struct MachineFacts: Sendable {
    public var model: String?
    public var coreCount: Int
    public var loadAverage: [Double]
    public var snapshot: SystemSnapshot
    /// Every process with its CPU and memory use, as sampled. Only names are ever reported.
    public var processes: [ProcessUsage]
    public var ports: [ListeningPort]
    public var containers: [DockerContainer]
    public var containerUsage: [String: DockerUsage]
    public var devices: [PeripheralDevice]
    public var volumes: [MountedVolume]
    /// The user running TaskBar. Processes owned by this user are labelled "you".
    public var currentUserID: UInt32

    public init(
        model: String? = nil,
        coreCount: Int = 0,
        loadAverage: [Double] = [],
        snapshot: SystemSnapshot = SystemSnapshot(),
        processes: [ProcessUsage] = [],
        ports: [ListeningPort] = [],
        containers: [DockerContainer] = [],
        containerUsage: [String: DockerUsage] = [:],
        devices: [PeripheralDevice] = [],
        volumes: [MountedVolume] = [],
        currentUserID: UInt32 = 0
    ) {
        self.model = model
        self.coreCount = coreCount
        self.loadAverage = loadAverage
        self.snapshot = snapshot
        self.processes = processes
        self.ports = ports
        self.containers = containers
        self.containerUsage = containerUsage
        self.devices = devices
        self.volumes = volumes
        self.currentUserID = currentUserID
    }
}

/// Turns the machine's facts into the compact plain-text summary sent to the assistant.
///
/// The text is data for the model, never instructions: names are cleaned of control characters and
/// shortened, and the whole report stays under `maxBytes`.
public enum MachineReport {
    public static let maxBytes = 4_000
    static let topByCPU = 15
    static let topByMemory = 10
    static let listLimit = 15
    static let deviceLimit = 8
    static let driveLimit = 6

    public static func text(for facts: MachineFacts) -> String {
        var lines = ["TaskBar machine snapshot, measured just now."]
        lines += systemLines(facts)
        lines += ["", "Top processes by CPU (name, pid, CPU as % of one core, memory, user):"]
        lines += processLines(facts.processes.sorted { ($0.cpuPercent, $0.memoryBytes) > ($1.cpuPercent, $1.memoryBytes) }.prefix(topByCPU), currentUserID: facts.currentUserID)
        lines += ["", "Top processes by memory (name, pid, CPU as % of one core, memory, user):"]
        lines += processLines(facts.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(topByMemory), currentUserID: facts.currentUserID)
        lines += ["", "Listening TCP ports (port, process, pid, service):"]
        lines += portLines(facts)
        lines += ["", "Docker containers (name, id, state, CPU and memory when known):"]
        lines += containerLines(facts)
        lines += ["", "Connected devices (battery):"]
        lines += deviceLines(facts)
        lines += ["", "Mounted drives:"]
        lines += driveLines(facts)
        return fit(lines.joined(separator: "\n"))
    }

    // MARK: Sections

    private static func systemLines(_ facts: MachineFacts) -> [String] {
        let snapshot = facts.snapshot
        var lines = ["Mac: \(facts.model ?? "unknown model"), \(facts.coreCount) CPU cores"]

        if let cpu = snapshot.cpu {
            let cores = cpu.perCore.map { percent($0) }.joined(separator: " ")
            lines.append("CPU: \(percent(cpu.overall)) overall; per core: \(cores)")
        } else {
            lines.append("CPU: not measured")
        }
        if !facts.loadAverage.isEmpty {
            let values = facts.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " ")
            lines.append("Load average (1, 5, 15 minutes): \(values)")
        }
        if let memory = snapshot.memory {
            lines.append(
                "Memory: \(Formatting.bytes(memory.usedBytes)) used of \(Formatting.bytes(memory.totalBytes)) "
                    + "(\(percent(memory.usedFraction))), pressure \(memory.pressure.label), "
                    + "swap used \(Formatting.bytes(memory.swapUsedBytes))"
            )
        } else {
            lines.append("Memory: not measured")
        }
        if let disk = snapshot.disk {
            lines.append(
                "Startup disk: \(Formatting.bytes(disk.availableBytes)) free of \(Formatting.bytes(disk.totalBytes))"
            )
        }
        if let battery = snapshot.battery {
            let charge = battery.isCharging ? "charging" : "not charging"
            let power = battery.isOnACPower ? "on AC power" : "on battery"
            lines.append("Battery: \(battery.percent)%, \(charge), \(power)")
        } else {
            lines.append("Battery: none reported")
        }
        lines.append("Thermal state: \(snapshot.thermal.label). Uptime: \(Formatting.uptime(snapshot.uptime))")
        return lines
    }

    private static func processLines(_ processes: some Collection<ProcessUsage>, currentUserID: UInt32) -> [String] {
        guard !processes.isEmpty else { return ["- none"] }
        return processes.map { process in
            "- \(clean(process.name)), pid \(process.pid), cpu \(Int(process.cpuPercent.rounded()))%, "
                + "memory \(Formatting.bytes(process.memoryBytes)), user \(owner(of: process.userID, current: currentUserID))"
        }
    }

    private static func portLines(_ facts: MachineFacts) -> [String] {
        guard !facts.ports.isEmpty else { return ["- none"] }
        return facts.ports.sorted { $0.port < $1.port }.prefix(listLimit).map { port in
            let service = port.service.map { ", \($0.label)" } ?? ""
            let scope = port.isLoopbackOnly ? "this Mac only" : "all interfaces"
            return "- \(port.port) \(clean(port.command)) pid \(port.pid)\(service), \(scope)"
        }
    }

    private static func containerLines(_ facts: MachineFacts) -> [String] {
        guard !facts.containers.isEmpty else { return ["- none"] }
        return facts.containers.prefix(listLimit).map { container in
            var line = "- \(clean(container.name)) (id \(String(container.id.prefix(12)))), \(clean(container.state))"
            if let usage = facts.containerUsage[container.id] {
                if let cpu = usage.cpuPercent { line += ", cpu \(Int(cpu.rounded()))%" }
                line += ", memory \(Formatting.bytes(usage.memoryBytes))"
            }
            return line
        }
    }

    private static func deviceLines(_ facts: MachineFacts) -> [String] {
        let devices = facts.devices.filter(\.hasBattery)
        guard !devices.isEmpty else { return ["- none"] }
        return devices.prefix(deviceLimit).map { device in
            var levels: [String] = []
            if let level = device.level { levels.append("battery \(level)%") }
            if let left = device.leftLevel { levels.append("left \(left)%") }
            if let right = device.rightLevel { levels.append("right \(right)%") }
            if let caseLevel = device.caseLevel { levels.append("case \(caseLevel)%") }
            if device.isCharging { levels.append("charging") }
            return "- \(clean(device.name)): \(levels.joined(separator: ", "))"
        }
    }

    private static func driveLines(_ facts: MachineFacts) -> [String] {
        guard !facts.volumes.isEmpty else { return ["- none"] }
        return facts.volumes.prefix(driveLimit).map { volume in
            let external = volume.isExternal ? ", external" : ""
            return "- \(clean(volume.name)): \(Formatting.bytes(volume.availableBytes)) free of "
                + "\(Formatting.bytes(volume.totalBytes)), \(percent(volume.usedFraction)) used\(external)"
        }
    }

    // MARK: Helpers

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// `you` for the user running TaskBar, `root` for system daemons, otherwise the numeric ID.
    static func owner(of userID: UInt32, current: UInt32) -> String {
        if userID == 0 { return "root" }
        if userID == current { return "you" }
        return "uid \(userID)"
    }

    /// One line of text: control characters become spaces, runs of spaces collapse, and long
    /// names are shortened. Names come from other programs, so they are never trusted as layout.
    static func clean(_ text: String, limit: Int = 48) -> String {
        let flattened = text.map { character in
            character.unicodeScalars.contains { $0.properties.generalCategory == .control } ? " " : character
        }
        let collapsed = String(flattened).split(separator: " ").joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 3)) + "..."
    }

    /// Keeps the report under `maxBytes`, dropping whole trailing lines when it would not fit.
    static func fit(_ text: String) -> String {
        guard text.utf8.count > maxBytes else { return text }
        let note = "(Report shortened to fit.)"
        var kept: [Substring] = []
        var size = note.utf8.count + 1
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            size += line.utf8.count + 1
            guard size <= maxBytes else { break }
            kept.append(line)
        }
        return (kept + [Substring(note)]).joined(separator: "\n")
    }
}
