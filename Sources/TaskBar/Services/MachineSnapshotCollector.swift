import Darwin
import Foundation
import TaskBarCore

/// Takes a fresh reading of this Mac for one question to the assistant.
///
/// It runs only when a question is sent. CPU and process use are differences between two readings,
/// so the counters are primed, then read again a second later. Nothing is kept: the facts live only
/// for the question they were gathered for.
@MainActor
final class MachineSnapshotCollector {
    private let metrics = SystemMetricsSampler()
    private let processes = ProcessSampler()
    private let docker = DockerClient()

    private static let readingGap: Duration = .seconds(1)

    func collect() async -> MachineFacts {
        _ = await metrics.sample()
        _ = await processes.sample()
        _ = await readContainers()
        try? await Task.sleep(for: Self.readingGap)

        let snapshot = await metrics.sample()
        let usages = await processes.sample().map { usage -> ProcessUsage in
            var usage = usage
            usage.name = ProcessInspector.fullName(of: usage.pid) ?? usage.name
            return usage
        }
        let (containers, containerUsage) = await readContainers()
        let ports = await ListeningPortScanner.scan() ?? []
        let (volumes, devices) = await Task.detached(priority: .utility) {
            (VolumeArrangement.arrange(VolumeProbe.mounted()), PeripheralProbes.registryDevices())
        }.value

        return MachineFacts(
            model: MachineIdentity.modelIdentifier(),
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            loadAverage: MachineIdentity.loadAverage(),
            snapshot: snapshot,
            processes: usages,
            ports: ports,
            containers: containers,
            containerUsage: containerUsage,
            devices: devices,
            volumes: volumes,
            currentUserID: getuid()
        )
    }

    /// Every container and the CPU and memory of the running ones. Empty when Docker is not running.
    private func readContainers() async -> ([DockerContainer], [String: DockerUsage]) {
        guard let containers = try? await docker.containers(includeStopped: true) else { return ([], [:]) }
        let usage = await docker.usage(for: containers.filter(\.isRunning).map(\.id))
        return (containers, usage)
    }
}
