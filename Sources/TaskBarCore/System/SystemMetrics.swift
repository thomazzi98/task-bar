import Foundation

/// Cumulative scheduler ticks of one CPU core.
public struct CPUTicks: Equatable, Sendable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user + system + nice }
    public var total: UInt64 { busy + idle }
}

/// CPU utilisation between two samples, as fractions in `0...1`.
public struct CPULoad: Equatable, Sendable {
    public var overall: Double
    public var perCore: [Double]

    public init(overall: Double, perCore: [Double]) {
        self.overall = overall
        self.perCore = perCore
    }
}

public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warning = 2
    case critical = 4

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

public struct MemoryUsage: Equatable, Sendable {
    public var totalBytes: UInt64
    /// App memory + wired + compressed, matching Activity Monitor's "Memory Used".
    public var usedBytes: UInt64
    public var appBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var cachedBytes: UInt64
    public var swapUsedBytes: UInt64
    public var pressure: MemoryPressure

    public init(
        totalBytes: UInt64,
        appBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedBytes: UInt64,
        swapUsedBytes: UInt64,
        pressure: MemoryPressure
    ) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
        self.usedBytes = min(appBytes + wiredBytes + compressedBytes, totalBytes)
    }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }
}

public struct DiskUsage: Equatable, Sendable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedFraction: Double {
        totalBytes == 0 ? 0 : 1 - Double(availableBytes) / Double(totalBytes)
    }
}

public struct BatteryStatus: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var isOnACPower: Bool
    /// Minutes until empty (on battery) or full (charging), when the system has an estimate.
    public var minutesRemaining: Int?

    public init(percent: Int, isCharging: Bool, isOnACPower: Bool, minutesRemaining: Int?) {
        self.percent = percent
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.minutesRemaining = minutesRemaining
    }
}

/// Cumulative bytes moved across the physical network interfaces.
public struct NetworkCounters: Equatable, Sendable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct NetworkRate: Equatable, Sendable {
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double

    public init(bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

public enum ThermalLevel: Int, Sendable {
    case nominal, fair, serious, critical

    public var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        }
    }
}

/// One reading of the machine's vital signs.
public struct SystemSnapshot: Equatable, Sendable {
    /// `nil` on the very first sample: CPU load needs two readings to compare.
    public var cpu: CPULoad?
    public var memory: MemoryUsage?
    public var disk: DiskUsage?
    public var battery: BatteryStatus?
    public var network: NetworkRate?
    public var uptime: TimeInterval
    public var thermal: ThermalLevel
    public var timestamp: Date

    public init(
        cpu: CPULoad? = nil,
        memory: MemoryUsage? = nil,
        disk: DiskUsage? = nil,
        battery: BatteryStatus? = nil,
        network: NetworkRate? = nil,
        uptime: TimeInterval = 0,
        thermal: ThermalLevel = .nominal,
        timestamp: Date = Date()
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.battery = battery
        self.network = network
        self.uptime = uptime
        self.thermal = thermal
        self.timestamp = timestamp
    }
}

/// Pure arithmetic over raw counters, kept apart from the system calls so it can be tested.
public enum SystemMath {
    public static func cpuLoad(from previous: [CPUTicks], to current: [CPUTicks]) -> CPULoad? {
        guard !current.isEmpty, previous.count == current.count else { return nil }

        var busyTotal: UInt64 = 0
        var allTotal: UInt64 = 0
        let perCore = zip(previous, current).map { before, after -> Double in
            let busy = after.busy >= before.busy ? after.busy - before.busy : 0
            let total = after.total >= before.total ? after.total - before.total : 0
            busyTotal += busy
            allTotal += total
            return total == 0 ? 0 : min(Double(busy) / Double(total), 1)
        }
        guard allTotal > 0 else { return nil }
        return CPULoad(overall: min(Double(busyTotal) / Double(allTotal), 1), perCore: perCore)
    }

    /// Transfer rate between two counter readings. Interface counters are 32-bit and wrap
    /// around every 4 GB, which is compensated for here.
    public static func networkRate(
        from previous: NetworkCounters,
        to current: NetworkCounters,
        elapsed: TimeInterval
    ) -> NetworkRate? {
        guard elapsed > 0 else { return nil }
        return NetworkRate(
            bytesInPerSecond: Double(wrappingDelta(previous.bytesIn, current.bytesIn)) / elapsed,
            bytesOutPerSecond: Double(wrappingDelta(previous.bytesOut, current.bytesOut)) / elapsed
        )
    }

    static func wrappingDelta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
        current >= previous ? current - previous : current + (UInt64(UInt32.max) + 1 - min(previous, UInt64(UInt32.max) + 1))
    }
}
