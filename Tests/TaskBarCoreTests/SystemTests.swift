import Foundation
import Testing
@testable import TaskBarCore

@Suite("System math")
struct SystemMathTests {
    @Test func computesCPULoadFromTickDeltas() throws {
        let before = [
            CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUTicks(user: 200, system: 100, idle: 700, nice: 0)
        ]
        let after = [
            CPUTicks(user: 150, system: 75, idle: 875, nice: 0), // 75 busy of 100
            CPUTicks(user: 210, system: 100, idle: 790, nice: 0) // 10 busy of 100
        ]
        let load = try #require(SystemMath.cpuLoad(from: before, to: after))
        #expect(load.perCore == [0.75, 0.10])
        #expect(abs(load.overall - 0.425) < 0.0001)
    }

    @Test func needsTwoComparableSamplesForCPULoad() {
        let sample = [CPUTicks(user: 1, system: 1, idle: 1, nice: 0)]
        #expect(SystemMath.cpuLoad(from: [], to: sample) == nil)
        #expect(SystemMath.cpuLoad(from: sample, to: sample) == nil)
        #expect(SystemMath.cpuLoad(from: sample, to: []) == nil)
    }

    @Test func toleratesCountersGoingBackwards() throws {
        let before = [CPUTicks(user: 500, system: 0, idle: 500, nice: 0)]
        let after = [CPUTicks(user: 400, system: 0, idle: 700, nice: 0)]
        let load = try #require(SystemMath.cpuLoad(from: before, to: after))
        #expect(load.overall == 0)
    }

    @Test func computesNetworkRates() throws {
        let rate = try #require(SystemMath.networkRate(
            from: NetworkCounters(bytesIn: 1_000, bytesOut: 500),
            to: NetworkCounters(bytesIn: 5_000, bytesOut: 1_500),
            elapsed: 2
        ))
        #expect(rate.bytesInPerSecond == 2_000)
        #expect(rate.bytesOutPerSecond == 500)
        #expect(SystemMath.networkRate(
            from: NetworkCounters(bytesIn: 0, bytesOut: 0),
            to: NetworkCounters(bytesIn: 1, bytesOut: 1),
            elapsed: 0
        ) == nil)
    }

    @Test func compensatesForWrappedInterfaceCounters() {
        let max32 = UInt64(UInt32.max)
        // The 32-bit counter wrapped from near its maximum back to a small value.
        #expect(SystemMath.wrappingDelta(max32 - 9, 90) == 100)
        #expect(SystemMath.wrappingDelta(10, 110) == 100)
    }

    @Test func derivesMemoryTotals() {
        let gigabyte: UInt64 = 1_073_741_824
        let memory = MemoryUsage(
            totalBytes: 16 * gigabyte,
            appBytes: 6 * gigabyte,
            wiredBytes: 2 * gigabyte,
            compressedBytes: 1 * gigabyte,
            cachedBytes: 4 * gigabyte,
            swapUsedBytes: 0,
            pressure: .normal
        )
        #expect(memory.usedBytes == 9 * gigabyte)
        #expect(memory.usedFraction == 0.5625)
        #expect(DiskUsage(totalBytes: 1000, availableBytes: 250).usedFraction == 0.75)
        #expect(DiskUsage(totalBytes: 0, availableBytes: 0).usedFraction == 0)
    }
}

@Suite("Process math")
struct ProcessMathTests {
    private func sample(_ pid: Int32, parent: Int32 = 1, cpu: UInt64, memory: UInt64 = 0, name: String = "proc") -> ProcessSample {
        ProcessSample(pid: pid, parentPID: parent, userID: 501, name: name, cpuTimeNanoseconds: cpu, memoryBytes: memory)
    }

    private func usage(_ pid: Int32, parent: Int32, cpu: Double, memory: UInt64, user: UInt32 = 501, name: String = "proc") -> ProcessUsage {
        ProcessUsage(pid: pid, parentPID: parent, userID: user, name: name, cpuPercent: cpu, memoryBytes: memory)
    }

    @Test func convertsCPUTimeDeltasToPercentages() {
        let previous: [Int32: ProcessSample] = [10: sample(10, cpu: 1_000_000_000)]
        let current = [
            sample(10, cpu: 2_000_000_000, memory: 512), // 1s of CPU in 2s -> 50%
            sample(11, cpu: 9_000_000_000) // first sighting -> unknown, reported as 0
        ]
        let usages = ProcessMath.usages(previous: previous, current: current, elapsed: 2)
        #expect(usages.map(\.cpuPercent) == [50, 0])
        #expect(usages.first?.memoryBytes == 512)
    }

    @Test func reportsZeroCPUWithoutAnElapsedInterval() {
        let previous: [Int32: ProcessSample] = [10: sample(10, cpu: 1)]
        let usages = ProcessMath.usages(previous: previous, current: [sample(10, cpu: 5_000_000_000)], elapsed: 0)
        #expect(usages.first?.cpuPercent == 0)
    }

    @Test func attributesHelpersToTheirApp() throws {
        // 100 (app) -> 101 (helper) -> 102 (renderer); 200 is another app; 300 is unrelated.
        let usages = [
            usage(100, parent: 1, cpu: 10, memory: 100),
            usage(101, parent: 100, cpu: 20, memory: 200),
            usage(102, parent: 101, cpu: 5, memory: 50),
            usage(200, parent: 1, cpu: 1, memory: 10),
            usage(300, parent: 1, cpu: 99, memory: 999)
        ]
        let totals = ProcessMath.aggregate(usages, byRoots: [100, 200])

        let app = try #require(totals[100])
        #expect(app.cpuPercent == 35)
        #expect(app.memoryBytes == 350)
        #expect(app.processCount == 3)
        #expect(totals[200] == ProcessGroupUsage(cpuPercent: 1, memoryBytes: 10, processCount: 1))
        #expect(totals[300] == nil)
    }

    @Test func nestedAppsKeepTheirOwnTotals() throws {
        // An app launched by another app (e.g. from a terminal) is its own root.
        let usages = [
            usage(100, parent: 1, cpu: 10, memory: 100),
            usage(150, parent: 100, cpu: 7, memory: 70),
            usage(151, parent: 150, cpu: 3, memory: 30)
        ]
        let totals = ProcessMath.aggregate(usages, byRoots: [100, 150])
        #expect(totals[100]?.processCount == 1)
        #expect(totals[150]?.cpuPercent == 10)
    }

    @Test func survivesParentCycles() {
        let usages = [usage(5, parent: 6, cpu: 1, memory: 1), usage(6, parent: 5, cpu: 1, memory: 1)]
        #expect(ProcessMath.aggregate(usages, byRoots: [999]).isEmpty)
    }

    @Test func protectsCriticalAndForeignProcesses() {
        func isProtected(_ usage: ProcessUsage) -> Bool {
            ProcessMath.isProtected(usage, currentUserID: 501, ownPID: 4242)
        }
        #expect(isProtected(usage(1, parent: 0, cpu: 0, memory: 0, name: "launchd")))
        #expect(isProtected(usage(4242, parent: 1, cpu: 0, memory: 0, name: "TaskBar")))
        #expect(isProtected(usage(88, parent: 1, cpu: 0, memory: 0, user: 0, name: "syslogd")))
        #expect(isProtected(usage(89, parent: 1, cpu: 0, memory: 0, name: "WindowServer")))
        #expect(!isProtected(usage(90, parent: 1, cpu: 0, memory: 0, name: "node")))
    }
}

@Suite("Live system probes")
struct LiveSystemProbeTests {
    @Test func samplesTheRealMachine() async {
        let sampler = SystemMetricsSampler()
        let first = await sampler.sample()
        // CPU load needs two readings; everything else is available immediately.
        #expect(first.cpu == nil)
        #expect((first.memory?.totalBytes ?? 0) > 0)
        #expect((first.memory?.usedBytes ?? 0) > 0)
        #expect((first.disk?.totalBytes ?? 0) > 0)
        #expect(first.uptime > 0)

        try? await Task.sleep(for: .milliseconds(150))
        let second = await sampler.sample()
        let load = second.cpu
        #expect(load != nil)
        #expect((load?.perCore.count ?? 0) == ProcessInfo.processInfo.processorCount)
        #expect((0...1).contains(load?.overall ?? -1))
    }

    @Test func inspectsTheCurrentProcess() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        #expect(ProcessInspector.isAlive(pid))
        #expect(!ProcessInspector.isAlive(-1))
        #expect(!ProcessInspector.isAlive(2_000_000_000))

        let details = try #require(ProcessInspector.details(of: pid))
        #expect(details.pid == pid)
        #expect(details.parentPID == getppid())
        #expect(details.userID == getuid())
        #expect(!details.name.isEmpty)

        let usage = try #require(ProcessInspector.resourceUsage(of: pid))
        #expect(usage.memoryBytes > 0)
        #expect(ProcessInspector.executablePath(of: pid)?.isEmpty == false)
        #expect(ProcessInspector.fullName(of: pid)?.isEmpty == false)
        #expect(ProcessInspector.fullName(of: 2_000_000_000) == nil)
        #expect(ProcessInspector.allPIDs().contains(pid))
        #expect(ProcessInspector.ancestors(of: pid).first == getppid())
    }

    @Test func listsProcessesWithUsage() async {
        let sampler = ProcessSampler()
        _ = await sampler.sample()
        let usages = await sampler.sample()
        let own = usages.first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        #expect(usages.count > 10)
        #expect((own?.memoryBytes ?? 0) > 0)
    }

    @Test func refusesToSignalReservedProcesses() {
        #expect(!ProcessInspector.send(signal: 0, to: 1))
        #expect(!ProcessInspector.send(signal: 0, to: 0))
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test func formatsByteCounts() {
        #expect(Formatting.bytes(512) == "512 B")
        #expect(Formatting.bytes(2_048) == "2 KB")
        #expect(Formatting.bytes(820 * 1_048_576) == "820 MB")
        #expect(Formatting.bytes(1_610_612_736) == "1.5 GB")
        #expect(Formatting.bytes(128 * 1_073_741_824) == "128 GB")
        #expect(Formatting.bytes(32 * 1_073_741_824) == "32 GB")
        #expect(Formatting.bytes(2 * 1_048_576) == "2 MB")
        // Small megabyte values keep a decimal so transfer rates do not look frozen.
        #expect(Formatting.bytes(2_516_582) == "2.4 MB")
        #expect(Formatting.rate(1_572_864) == "1.5 MB/s")
        #expect(Formatting.rate(-5) == "0 B/s")
    }

    @Test func formatsPercentagesAndUptime() {
        #expect(Formatting.percent(0.426) == "43%")
        #expect(Formatting.uptime(300) == "5m")
        #expect(Formatting.uptime(18_720) == "5h 12m")
        #expect(Formatting.uptime(273_600) == "3d 4h")
    }
}
