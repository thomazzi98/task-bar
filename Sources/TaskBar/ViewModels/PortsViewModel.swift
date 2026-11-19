import Foundation
import Observation
import TaskBarCore

/// Listening TCP ports for the System tab, with stop and force quit.
///
/// Sampling runs only while the System tab is visible (`setVisible`). Each pass runs lsof off
/// the main actor. Nothing runs while the popover is closed.
@MainActor
@Observable
final class PortsViewModel {
    private(set) var ports: [ListeningPort] = []
    /// Ports still listening some time after SIGTERM, which offer a force quit.
    private(set) var stubborn: Set<ListeningPort.ID> = []
    private(set) var notice: String?
    var filter: PortFilter = .all

    @ObservationIgnored private var signalledAt: [ListeningPort.ID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var isVisible = false

    private static let refreshInterval: Duration = .seconds(5)
    private static let gracePeriod: Duration = .seconds(2)
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let currentUserID = getuid()

    var visiblePorts: [ListeningPort] {
        ports.filter { filter.includes($0.service) }
    }

    func block(for port: ListeningPort) -> PortStopRules.Block? {
        PortStopRules.block(for: port, currentUserID: currentUserID, ownPID: ownPID)
    }

    // MARK: Sampling control

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        pollTask?.cancel()
        pollTask = nil
        guard visible else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    // MARK: Actions

    /// Asks the process to quit (SIGTERM). If its port is still open after the grace period,
    /// the row offers a force quit.
    func stop(_ port: ListeningPort) {
        send(SIGTERM, to: port)
    }

    func forceQuit(_ port: ListeningPort) {
        send(SIGKILL, to: port)
    }

    private func send(_ signal: Int32, to port: ListeningPort) {
        guard block(for: port) == nil else { return }
        guard ProcessInspector.send(signal: signal, to: port.pid) else {
            notice = "Could not signal \(port.command) (PID \(String(port.pid)))."
            return
        }
        notice = nil
        if signal == SIGTERM {
            signalledAt[port.id] = ContinuousClock.now
            scheduleRefresh(after: Self.gracePeriod + .milliseconds(200))
        } else {
            signalledAt.removeValue(forKey: port.id)
            stubborn.remove(port.id)
            scheduleRefresh(after: .milliseconds(600))
        }
    }

    // MARK: Private

    private func refresh() async {
        guard isVisible, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // A failed scan keeps the last good list rather than blanking the section.
        guard let scanned = await ListeningPortScanner.scan(), isVisible else { return }
        if scanned != ports { ports = scanned }

        let now = ContinuousClock.now
        let live = Set(scanned.map(\.id))
        signalledAt = signalledAt.filter { live.contains($0.key) }
        let overdue = Set(signalledAt.filter { now - $0.value >= Self.gracePeriod }.keys)
        if overdue != stubborn { stubborn = overdue }
    }

    private func scheduleRefresh(after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.refresh()
        }
    }
}
