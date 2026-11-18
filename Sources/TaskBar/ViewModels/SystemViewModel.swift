import AppKit
import Observation
import TaskBarCore

/// An open application with the combined usage of all its processes.
struct RunningAppUsage: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    var usage: ProcessGroupUsage

    var id: Int32 { pid }

    static func == (lhs: RunningAppUsage, rhs: RunningAppUsage) -> Bool {
        lhs.pid == rhs.pid && lhs.name == rhs.name && lhs.usage == rhs.usage
    }
}

enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu, memory

    var id: String { rawValue }
    var label: String { self == .cpu ? "CPU" : "Memory" }
}

/// Machine vitals, open apps, top processes and Docker containers.
///
/// Sampling is strictly demand-driven. `setPanelVisible` runs a cheap CPU/memory sample while
/// the popover is open (it feeds the footer), and `setDetailVisible` adds the process and
/// container scans only while the System tab is showing. With the popover closed, no timer runs.
@MainActor
@Observable
final class SystemViewModel {
    private(set) var snapshot: SystemSnapshot?
    /// Recent CPU load samples (0...1), oldest first, for the sparkline.
    private(set) var cpuHistory: [Double] = []
    private(set) var apps: [RunningAppUsage] = []
    private(set) var processes: [ProcessUsage] = []
    private(set) var containers: [DockerContainer] = []
    private(set) var containerUsage: [String: DockerUsage] = [:]
    private(set) var isDockerAvailable = false
    /// Container IDs with a start/stop/restart in flight.
    private(set) var busyContainers: Set<String> = []
    private(set) var actionMessage: String?
    var processSort: ProcessSortKey = .cpu

    @ObservationIgnored var showsStoppedContainers = false

    @ObservationIgnored private let metrics = SystemMetricsSampler()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private let docker = DockerClient()
    @ObservationIgnored private var vitalsTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var latestUsages: [ProcessUsage] = []
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var isDetailVisible = false

    private static let historyLength = 40
    private static let processLimit = 8
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let currentUserID = getuid()

    // MARK: Sampling control

    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        vitalsTask?.cancel()
        vitalsTask = nil
        guard visible else { return }

        vitalsTask = Task { [weak self] in
            // CPU load needs two readings, so take the second one quickly, then settle down.
            await self?.sampleVitals()
            try? await Task.sleep(for: .milliseconds(700))
            while !Task.isCancelled {
                await self?.sampleVitals()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func setDetailVisible(_ visible: Bool) {
        guard visible != isDetailVisible else { return }
        isDetailVisible = visible
        detailTask?.cancel()
        detailTask = nil
        guard visible else { return }

        detailTask = Task { [weak self] in
            await self?.sampleProcesses()
            try? await Task.sleep(for: .milliseconds(900))
            while !Task.isCancelled {
                await self?.sampleProcesses()
                await self?.refreshContainers()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: Derived values

    var runningContainerCount: Int {
        containers.reduce(0) { $0 + ($1.isRunning ? 1 : 0) }
    }

    func isProtected(_ process: ProcessUsage) -> Bool {
        ProcessMath.isProtected(process, currentUserID: currentUserID, ownPID: ownPID)
    }

    // MARK: Actions on apps and processes

    func quit(_ app: RunningAppUsage, force: Bool) {
        guard let running = NSRunningApplication(processIdentifier: app.pid) else { return }
        let accepted = force ? running.forceTerminate() : running.terminate()
        actionMessage = accepted
            ? (force ? "Force quit \(app.name)." : "Asked \(app.name) to quit.")
            : "\(app.name) did not respond."
        refreshSoon()
    }

    func terminate(_ process: ProcessUsage, force: Bool) {
        guard !isProtected(process) else { return }
        let delivered = ProcessInspector.send(signal: force ? SIGKILL : SIGTERM, to: process.pid)
        actionMessage = delivered
            ? (force ? "Killed \(process.name)." : "Asked \(process.name) to stop.")
            : "Could not signal \(process.name)."
        refreshSoon()
    }

    // MARK: Actions on containers

    func perform(_ action: DockerAction, on container: DockerContainer) {
        guard !busyContainers.contains(container.id) else { return }
        busyContainers.insert(container.id)
        Task { [weak self, docker] in
            var failure: String?
            do {
                try await docker.perform(action, on: container.id)
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.busyContainers.remove(container.id)
            self.actionMessage = failure ?? "\(action.pastTense) \(container.name)."
            await self.refreshContainers()
        }
    }

    func clearActionMessage() {
        actionMessage = nil
    }

    /// Replaces the displayed data. Used by previews and snapshot rendering.
    func applyPreview(
        snapshot: SystemSnapshot,
        cpuHistory: [Double],
        apps: [RunningAppUsage],
        processes: [ProcessUsage],
        containers: [DockerContainer],
        containerUsage: [String: DockerUsage]
    ) {
        self.snapshot = snapshot
        self.cpuHistory = cpuHistory
        self.apps = apps
        self.processes = processes
        self.containers = containers
        self.containerUsage = containerUsage
        isDockerAvailable = !containers.isEmpty
    }

    // MARK: Private sampling

    private func sampleVitals() async {
        let reading = await metrics.sample()
        guard !Task.isCancelled else { return }
        snapshot = reading
        if let load = reading.cpu?.overall {
            cpuHistory.append(load)
            if cpuHistory.count > Self.historyLength {
                cpuHistory.removeFirst(cpuHistory.count - Self.historyLength)
            }
        }
    }

    private func sampleProcesses() async {
        let usages = await processSampler.sample()
        guard !Task.isCancelled else { return }
        latestUsages = usages
        rebuildLists()
    }

    private func rebuildLists() {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let totals = ProcessMath.aggregate(latestUsages, byRoots: Set(running.map(\.processIdentifier)))

        let appRows = running.map { app in
            RunningAppUsage(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                bundleIdentifier: app.bundleIdentifier,
                icon: app.icon,
                usage: totals[app.processIdentifier] ?? ProcessGroupUsage()
            )
        }
        .sorted { lhs, rhs in
            lhs.usage.memoryBytes != rhs.usage.memoryBytes
                ? lhs.usage.memoryBytes > rhs.usage.memoryBytes
                : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        if appRows != apps { apps = appRows }

        let top = latestUsages
            .sorted { lhs, rhs in
                switch processSort {
                case .cpu: lhs.cpuPercent != rhs.cpuPercent ? lhs.cpuPercent > rhs.cpuPercent : lhs.memoryBytes > rhs.memoryBytes
                case .memory: lhs.memoryBytes > rhs.memoryBytes
                }
            }
            .prefix(Self.processLimit)
            // Only the few rows on screen pay for resolving the untruncated name.
            .map { usage -> ProcessUsage in
                var usage = usage
                usage.name = ProcessInspector.fullName(of: usage.pid) ?? usage.name
                return usage
            }
        if top != processes { processes = top }
    }

    /// Re-sorts the process list right away when the sort key changes.
    func resortProcesses() {
        rebuildLists()
    }

    private func refreshContainers() async {
        let includeStopped = showsStoppedContainers
        do {
            let listed = try await docker.containers(includeStopped: includeStopped)
            let usage = await docker.usage(for: listed.filter(\.isRunning).map(\.id))
            guard !Task.isCancelled else { return }
            isDockerAvailable = true
            if listed != containers { containers = listed }
            if usage != containerUsage { containerUsage = usage }
        } catch {
            guard !Task.isCancelled else { return }
            isDockerAvailable = false
            if !containers.isEmpty { containers = [] }
            if !containerUsage.isEmpty { containerUsage = [:] }
        }
    }

    /// Runs one extra pass shortly after an action, so the list reflects it without waiting.
    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await self?.sampleProcesses()
        }
    }
}

private extension DockerAction {
    var pastTense: String {
        switch self {
        case .start: "Started"
        case .stop: "Stopped"
        case .restart: "Restarted"
        }
    }
}
