import AppKit
import Observation
import TaskBarCore

/// Battery levels of connected peripherals and the mounted drives, shown in the System tab.
///
/// Nothing runs while the tab is hidden. While it is visible, the IORegistry and volumes are read
/// every 10 seconds and `system_profiler` at most once a minute, always off the main actor.
@MainActor
@Observable
final class PeripheralsViewModel {
    /// Devices that report a battery, sorted by name.
    private(set) var devices: [PeripheralDevice] = []
    private(set) var volumes: [MountedVolume] = []
    /// Volumes with an eject in flight.
    private(set) var ejectingVolumeIDs: Set<String> = []
    private(set) var actionMessage: String?

    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var mountWatchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastBluetoothRead: Date?
    @ObservationIgnored private var bluetoothDevices: [PeripheralDevice] = []

    private static let pollInterval: Duration = .seconds(10)
    private static let bluetoothInterval: TimeInterval = 60
    private static let bluetoothTimeout: TimeInterval = 10

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        pollTask?.cancel()
        pollTask = nil
        mountWatchTasks.forEach { $0.cancel() }
        mountWatchTasks = []
        guard visible else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        // A drive plugged in or removed shows up at once, without waiting for the next poll.
        mountWatchTasks = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            Task { [weak self] in
                for await _ in NSWorkspace.shared.notificationCenter.notifications(named: name) {
                    await self?.refresh()
                }
            }
        }
    }

    func clearActionMessage() {
        actionMessage = nil
    }

    /// Opens the drive in Finder.
    func open(_ volume: MountedVolume) {
        NSWorkspace.shared.open(volume.url)
    }

    /// Unmounts and ejects the drive. The work runs off the main actor, as it can take a while.
    func eject(_ volume: MountedVolume) {
        let id = volume.id
        guard !ejectingVolumeIDs.contains(id) else { return }
        ejectingVolumeIDs.insert(id)
        let url = volume.url
        let name = volume.name
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            self.ejectingVolumeIDs.remove(id)
            self.actionMessage = failure.map { "Could not eject \(name): \($0)" } ?? "Ejected \(name)."
            await self.refresh()
        }
    }

    // MARK: Sampling

    private func refresh() async {
        let now = Date()
        let readsBluetooth = lastBluetoothRead.map { now.timeIntervalSince($0) >= Self.bluetoothInterval } ?? true
        if readsBluetooth { lastBluetoothRead = now }

        let timeout = Self.bluetoothTimeout
        let reading = await Task.detached(priority: .utility) { () -> Reading in
            Reading(
                volumes: VolumeProbe.mounted(),
                registry: PeripheralProbes.registryDevices(),
                bluetooth: readsBluetooth ? PeripheralProbes.bluetoothDevices(timeout: timeout) : nil
            )
        }.value

        // The tab may have been hidden while the reading was in flight.
        guard isVisible else { return }
        if let bluetooth = reading.bluetooth { bluetoothDevices = bluetooth }

        let merged = PeripheralMerge.merge(bluetoothDevices, reading.registry)
        if merged != devices { devices = merged }
        let arranged = VolumeArrangement.arrange(reading.volumes)
        if arranged != volumes { volumes = arranged }
    }

    /// The raw results of one background pass.
    private struct Reading: Sendable {
        var volumes: [MountedVolume]
        var registry: [PeripheralDevice]
        /// `nil` when `system_profiler` was not run in this pass.
        var bluetooth: [PeripheralDevice]?
    }
}
