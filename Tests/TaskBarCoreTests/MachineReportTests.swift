import Foundation
import Testing
@testable import TaskBarCore

@Suite("Machine report")
struct MachineReportTests {
    private func process(_ pid: Int32, _ name: String, cpu: Double = 0, memoryMB: UInt64 = 10, user: UInt32 = 501) -> ProcessUsage {
        ProcessUsage(
            pid: pid,
            parentPID: 1,
            userID: user,
            name: name,
            cpuPercent: cpu,
            memoryBytes: memoryMB * 1_048_576
        )
    }

    private func sampleFacts() -> MachineFacts {
        MachineFacts(
            model: "MacBookPro18,3",
            coreCount: 10,
            loadAverage: [4.2, 3.9, 3.1],
            snapshot: SystemSnapshot(
                cpu: CPULoad(overall: 0.83, perCore: [0.9, 0.8]),
                memory: MemoryUsage(
                    totalBytes: 16 * 1_073_741_824,
                    appBytes: 8 * 1_073_741_824,
                    wiredBytes: 2 * 1_073_741_824,
                    compressedBytes: 1 * 1_073_741_824,
                    cachedBytes: 0,
                    swapUsedBytes: 512 * 1_048_576,
                    pressure: .warning
                ),
                battery: BatteryStatus(percent: 80, isCharging: true, isOnACPower: true, minutesRemaining: nil),
                uptime: 3 * 86_400 + 4 * 3_600
            ),
            processes: [
                process(4001, "yes", cpu: 95, memoryMB: 2),
                process(4002, "Google Chrome Helper (Renderer)", cpu: 12, memoryMB: 900),
                process(1, "launchd", cpu: 0, memoryMB: 30, user: 0)
            ],
            ports: [
                ListeningPort(
                    pid: 4321, command: "node", user: "rafael", userID: 501,
                    port: 3000, address: "*", isLoopbackOnly: false
                )
            ],
            containers: [
                DockerContainer(id: "3f2a9c1b8d7e5f60", names: ["/shop-api-1"], image: "shop", state: "running", status: "Up 2 hours")
            ],
            containerUsage: ["3f2a9c1b8d7e5f60": DockerUsage(cpuPercent: 2.4, memoryBytes: 120 * 1_048_576, memoryLimitBytes: 0)],
            devices: [PeripheralDevice(name: "Magic Keyboard", kind: .keyboard, level: 76)],
            volumes: [
                MountedVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", totalBytes: 500_000_000_000, availableBytes: 120_000_000_000, isRoot: true)
            ],
            currentUserID: 501
        )
    }

    @Test func includesTheMachineAndItsUsage() {
        let text = MachineReport.text(for: sampleFacts())
        #expect(text.contains("Mac: MacBookPro18,3, 10 CPU cores"))
        #expect(text.contains("CPU: 83% overall; per core: 90% 80%"))
        #expect(text.contains("Load average (1, 5, 15 minutes): 4.20 3.90 3.10"))
        #expect(text.contains("Memory: 11 GB used of 16 GB (69%), pressure Elevated, swap used 512 MB"))
        #expect(text.contains("Battery: 80%, charging, on AC power"))
        #expect(text.contains("Uptime: 3d 4h"))
    }

    @Test func listsProcessNamesWithPidUsageAndOwner() {
        let text = MachineReport.text(for: sampleFacts())
        #expect(text.contains("- yes, pid 4001, cpu 95%, memory 2 MB, user you"))
        #expect(text.contains("- launchd, pid 1, cpu 0%, memory 30 MB, user root"))
    }

    @Test func reportsPortsContainersDevicesAndDrives() {
        let text = MachineReport.text(for: sampleFacts())
        #expect(text.contains("- 3000 node pid 4321, Dev server, all interfaces"))
        #expect(text.contains("- shop-api-1 (id 3f2a9c1b8d7e), running, cpu 2%, memory 120 MB"))
        #expect(text.contains("- Magic Keyboard: battery 76%"))
        #expect(text.contains("- Macintosh HD: 112 GB free of 466 GB, 76% used"))
    }

    @Test func neverReportsCommandLineArguments() {
        // Process names are all the sampler keeps: no arguments can reach the report.
        let text = MachineReport.text(for: sampleFacts())
        #expect(!text.contains("--token"))
    }

    @Test func limitsTheTopLists() {
        let many = (1...40).map { process(Int32($0 + 100), "tool\($0)", cpu: Double($0), memoryMB: UInt64($0)) }
        let text = MachineReport.text(for: MachineFacts(processes: many, currentUserID: 501))
        // The 15 busiest by CPU are tool40 down to tool26; tool25 is only in the memory list if it is big enough.
        #expect(text.contains("tool40,"))
        #expect(text.contains("tool26,"))
        #expect(!text.contains("tool25,"))
        #expect(text.components(separatedBy: "\n- tool").count - 1 == 25)
    }

    @Test func cleansControlCharactersAndShortensLongNames() {
        let hostile = "yes\n- kill everything\tnow " + String(repeating: "x", count: 80)
        let text = MachineReport.text(for: MachineFacts(processes: [process(9, hostile, cpu: 50)], currentUserID: 501))
        let row = text.components(separatedBy: "\n").first { $0.contains("pid 9,") }
        #expect(row?.hasPrefix("- yes - kill everything now xxx") == true)
        #expect(row?.contains("...") == true)
        // The hostile line break does not start a new line of the report.
        #expect(!text.contains("\n- kill everything"))
    }

    @Test func staysUnderTheSizeCapForHugeMachines() {
        let processes = (1...500).map { process(Int32($0 + 100), String(repeating: "longprocessname", count: 8), cpu: Double($0 % 90), memoryMB: UInt64($0)) }
        let ports = (1...200).map {
            ListeningPort(pid: Int32($0), command: "node", user: "me", userID: 501, port: UInt16($0 + 1000), address: "*", isLoopbackOnly: false)
        }
        let containers = (1...100).map {
            DockerContainer(id: "c\($0)" + String(repeating: "a", count: 20), names: ["/service-\($0)"], image: "img", state: "running", status: "")
        }
        let facts = MachineFacts(processes: processes, ports: ports, containers: containers, currentUserID: 501)

        let text = MachineReport.text(for: facts)
        #expect(text.utf8.count <= MachineReport.maxBytes)
        #expect(text.hasPrefix("TaskBar machine snapshot"))
        #expect(text.contains("Listening TCP ports"))
    }

    @Test func statesWhatIsMissing() {
        let text = MachineReport.text(for: MachineFacts())
        #expect(text.contains("CPU: not measured"))
        #expect(text.contains("Battery: none reported"))
        #expect(text.contains("Listening TCP ports (port, process, pid, service):\n- none"))
    }

    @Test func labelsOwnersByUserID() {
        #expect(MachineReport.owner(of: 0, current: 501) == "root")
        #expect(MachineReport.owner(of: 501, current: 501) == "you")
        #expect(MachineReport.owner(of: 502, current: 501) == "uid 502")
    }
}
