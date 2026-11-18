import Darwin
import Foundation

/// A raw per-process reading taken at one instant.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String
    public var cpuTimeNanoseconds: UInt64
    public var memoryBytes: UInt64

    public init(
        pid: Int32,
        parentPID: Int32,
        userID: UInt32,
        name: String,
        cpuTimeNanoseconds: UInt64,
        memoryBytes: UInt64
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.cpuTimeNanoseconds = cpuTimeNanoseconds
        self.memoryBytes = memoryBytes
    }
}

/// CPU and memory use of a process over the last sampling interval.
public struct ProcessUsage: Identifiable, Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var userID: UInt32
    public var name: String
    /// Percentage of one core, so a process using two full cores reports 200.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(
        pid: Int32,
        parentPID: Int32,
        userID: UInt32,
        name: String,
        cpuPercent: Double,
        memoryBytes: UInt64
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// Combined usage of an app and all of its helper processes.
public struct ProcessGroupUsage: Equatable, Sendable {
    public var cpuPercent: Double = 0
    public var memoryBytes: UInt64 = 0
    public var processCount: Int = 0

    public init(cpuPercent: Double = 0, memoryBytes: UInt64 = 0, processCount: Int = 0) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }
}

public enum ProcessMath {
    /// Converts two rounds of samples into per-process usage. Processes without an earlier
    /// sample report 0% CPU, since there is nothing to compare against yet.
    public static func usages(
        previous: [Int32: ProcessSample],
        current: [ProcessSample],
        elapsed: TimeInterval
    ) -> [ProcessUsage] {
        current.map { sample in
            var cpuPercent = 0.0
            if elapsed > 0, let before = previous[sample.pid],
               sample.cpuTimeNanoseconds >= before.cpuTimeNanoseconds {
                let used = Double(sample.cpuTimeNanoseconds - before.cpuTimeNanoseconds) / 1_000_000_000
                cpuPercent = used / elapsed * 100
            }
            return ProcessUsage(
                pid: sample.pid,
                parentPID: sample.parentPID,
                userID: sample.userID,
                name: sample.name,
                cpuPercent: cpuPercent,
                memoryBytes: sample.memoryBytes
            )
        }
    }

    /// Sums each process into the nearest ancestor listed in `roots` (itself included).
    /// This is how an app's helpers, renderers and child tools are attributed to the app.
    public static func aggregate(_ usages: [ProcessUsage], byRoots roots: Set<Int32>) -> [Int32: ProcessGroupUsage] {
        let parents = Dictionary(usages.map { ($0.pid, $0.parentPID) }, uniquingKeysWith: { first, _ in first })
        var totals: [Int32: ProcessGroupUsage] = [:]

        for usage in usages {
            var current = usage.pid
            var hops = 0
            var owner: Int32?
            while hops < 64 {
                if roots.contains(current) {
                    owner = current
                    break
                }
                guard let parent = parents[current], parent > 1, parent != current else { break }
                current = parent
                hops += 1
            }
            guard let owner else { continue }
            totals[owner, default: ProcessGroupUsage()].cpuPercent += usage.cpuPercent
            totals[owner, default: ProcessGroupUsage()].memoryBytes += usage.memoryBytes
            totals[owner, default: ProcessGroupUsage()].processCount += 1
        }
        return totals
    }

    /// Processes that must never be offered for termination from the UI.
    public static func isProtected(_ usage: ProcessUsage, currentUserID: UInt32, ownPID: Int32) -> Bool {
        if usage.pid <= 1 || usage.pid == ownPID { return true }
        if usage.userID != currentUserID { return true }
        return protectedNames.contains(usage.name)
    }

    private static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "SystemUIServer", "ControlCenter"
    ]
}

/// Samples every process on the machine and reports usage since the previous sample.
public actor ProcessSampler {
    private var previous: [Int32: ProcessSample] = [:]
    private var previousAt: Date?

    public init() {}

    public func sample(now: Date = Date()) -> [ProcessUsage] {
        let samples = ProcessInspector.allPIDs().compactMap { pid -> ProcessSample? in
            guard let details = ProcessInspector.details(of: pid) else { return nil }
            // Resource usage is unavailable for other users' processes; list them anyway.
            let usage = ProcessInspector.resourceUsage(of: pid)
            return ProcessSample(
                pid: pid,
                parentPID: details.parentPID,
                userID: details.userID,
                name: details.name,
                cpuTimeNanoseconds: usage?.cpuTimeNanoseconds ?? 0,
                memoryBytes: usage?.memoryBytes ?? 0
            )
        }

        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        let usages = ProcessMath.usages(previous: previous, current: samples, elapsed: elapsed)
        previous = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        previousAt = now
        return usages
    }
}
