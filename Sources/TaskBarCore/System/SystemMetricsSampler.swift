import Darwin
import Foundation
import IOKit.ps

/// Samples CPU, memory, disk, battery and network counters.
///
/// The sampler does nothing on its own: callers decide when to call `sample()`, which lets the
/// app stay completely idle while its window is closed.
public actor SystemMetricsSampler {
    private var previousTicks: [CPUTicks] = []
    private var previousNetwork: (counters: NetworkCounters, at: Date)?
    /// Disk space and battery change slowly and are comparatively expensive to read, so they
    /// are refreshed at most this often.
    private static let slowReadingInterval: TimeInterval = 20
    private var slowReadings: (disk: DiskUsage?, battery: BatteryStatus?, at: Date)?

    public init() {}

    public func sample(now: Date = Date()) -> SystemSnapshot {
        let ticks = SystemProbes.cpuTicks()
        let cpu = SystemMath.cpuLoad(from: previousTicks, to: ticks)
        previousTicks = ticks

        var network: NetworkRate?
        if let counters = SystemProbes.networkCounters() {
            if let previous = previousNetwork {
                network = SystemMath.networkRate(
                    from: previous.counters,
                    to: counters,
                    elapsed: now.timeIntervalSince(previous.at)
                )
            }
            previousNetwork = (counters, now)
        }

        if slowReadings.map({ now.timeIntervalSince($0.at) >= Self.slowReadingInterval }) ?? true {
            slowReadings = (SystemProbes.disk(), SystemProbes.battery(), now)
        }

        return SystemSnapshot(
            cpu: cpu,
            memory: SystemProbes.memory(),
            disk: slowReadings?.disk,
            battery: slowReadings?.battery,
            network: network,
            uptime: ProcessInfo.processInfo.systemUptime,
            thermal: SystemProbes.thermal(),
            timestamp: now
        )
    }
}

/// Raw readings from Mach, `sysctl`, IOKit and the file system.
enum SystemProbes {
    static func cpuTicks() -> [CPUTicks] {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(currentTask, host) }

        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            let size = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(currentTask, vm_address_t(bitPattern: info), size)
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        return (0..<Int(coreCount)).map { core in
            func ticks(_ state: Int32) -> UInt64 {
                UInt64(UInt32(bitPattern: info[core * statesPerCore + Int(state)]))
            }
            return CPUTicks(
                user: ticks(CPU_STATE_USER),
                system: ticks(CPU_STATE_SYSTEM),
                idle: ticks(CPU_STATE_IDLE),
                nice: ticks(CPU_STATE_NICE)
            )
        }
    }

    static func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(currentTask, host) }

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(host, HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(getpagesize())
        let internalPages = UInt64(stats.internal_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)
        let appPages = internalPages >= purgeablePages ? internalPages - purgeablePages : 0

        return MemoryUsage(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            appBytes: appPages * pageSize,
            wiredBytes: UInt64(stats.wire_count) * pageSize,
            compressedBytes: UInt64(stats.compressor_page_count) * pageSize,
            cachedBytes: (UInt64(stats.external_page_count) + purgeablePages) * pageSize,
            swapUsedBytes: swapUsed(),
            pressure: memoryPressure()
        )
    }

    static func disk() -> DiskUsage? {
        let root = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? root.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskUsage(totalBytes: UInt64(max(total, 0)), availableBytes: UInt64(max(available, 0)))
    }

    static func battery() -> BatteryStatus? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                let current = description[kIOPSCurrentCapacityKey] as? Int,
                let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isOnACPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let remainingKey = isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let remaining = description[remainingKey] as? Int

            return BatteryStatus(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: isCharging,
                isOnACPower: isOnACPower,
                minutesRemaining: remaining.flatMap { $0 > 0 ? $0 : nil }
            )
        }
        return nil
    }

    /// Total traffic over Ethernet and Wi-Fi interfaces (`en*`). Virtual interfaces are
    /// skipped so VPN traffic is not counted twice.
    static func networkCounters() -> NetworkCounters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var counters = NetworkCounters(bytesIn: 0, bytesOut: 0)
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = interface.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.ifa_data,
                  String(cString: entry.ifa_name).hasPrefix("en")
            else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters.bytesIn += UInt64(stats.ifi_ibytes)
            counters.bytesOut += UInt64(stats.ifi_obytes)
        }
        return counters
    }

    static func thermal() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    // MARK: Private

    private static var currentTask: mach_port_t { mach_task_self_ }

    private static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }
}
