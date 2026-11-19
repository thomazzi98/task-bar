import CoreBluetooth
import Foundation
import TaskBarCore

/// Reads the battery of connected Bluetooth LE keyboards and mice through the standard GATT
/// Battery Service (0x180F, Battery Level 0x2A19).
///
/// The central manager is created on the first read, which is what triggers the Bluetooth
/// permission prompt. Each read attaches to the connected peripherals briefly, reads the level and
/// releases them again. A read never waits longer than its timeout and returns whatever it got.
/// Everything runs on the main queue, so the state lives on the main actor.
@MainActor
final class BLEBatteryReader: NSObject {
    /// The last Bluetooth state reported. `.unauthorized` means the user denied access.
    private(set) var state: CBManagerState = .unknown

    private let batteryServiceID = CBUUID(string: "180F")
    private let hidServiceID = CBUUID(string: "1812")
    private let batteryLevelID = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    /// The read in flight, if any. Set while waiting for results.
    private var waiter: CheckedContinuation<[PeripheralDevice], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var hasStartedScan = false
    /// Peripherals still being read, by identifier.
    private var pending: [UUID: PendingPeripheral] = [:]
    private var results: [PeripheralDevice] = []

    private struct PendingPeripheral {
        let peripheral: CBPeripheral
        let name: String
    }

    /// Returns the battery levels read from connected peripherals. Returns what was collected so far
    /// when the timeout expires, and an empty list when Bluetooth is off, denied or unsupported.
    /// A second call while a read is in flight returns an empty list at once.
    func read(timeout: Duration = .seconds(6)) async -> [PeripheralDevice] {
        guard waiter == nil else { return [] }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            results = []
            hasStartedScan = false
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return // Finished earlier; a newer read must not be cut short.
                }
                self?.finish()
            }
            handleState()
        }
    }

    // MARK: State and collection

    private func handleState() {
        guard waiter != nil else { return }
        switch state {
        case .poweredOn:
            if !hasStartedScan { startReading() }
        case .unknown, .resetting:
            break // Still starting up. The timeout bounds the wait.
        default:
            finish() // Powered off, denied or unsupported: nothing to read.
        }
    }

    private func startReading() {
        guard let central else { return }
        hasStartedScan = true

        var found: [UUID: CBPeripheral] = [:]
        for service in [batteryServiceID, hidServiceID] {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) {
                found[peripheral.identifier] = peripheral
            }
        }
        for peripheral in found.values {
            guard let name = peripheral.name, !name.isEmpty else { continue }
            pending[peripheral.identifier] = PendingPeripheral(peripheral: peripheral, name: name)
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
        if pending.isEmpty { finish() }
    }

    /// Ends one peripheral's read, with its level if it reported one.
    private func complete(_ id: UUID, level: Int?) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        if let level {
            results.append(PeripheralDevice(
                name: entry.name,
                kind: PeripheralKind(minorType: nil, name: entry.name),
                level: level
            ))
        }
        // Releases only our attachment. The system keeps the device connected.
        central?.cancelPeripheralConnection(entry.peripheral)
        if pending.isEmpty { finish() }
    }

    /// Resumes the read in flight with what was collected and releases every peripheral.
    private func finish() {
        guard let waiter else { return }
        self.waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        for entry in pending.values {
            central?.cancelPeripheralConnection(entry.peripheral)
        }
        pending = [:]
        let devices = results
        results = []
        waiter.resume(returning: devices)
    }

    private func didUpdate(state newState: CBManagerState) {
        state = newState
        handleState()
    }

    private func discoverBatteryService(_ id: UUID) {
        pending[id]?.peripheral.discoverServices([batteryServiceID])
    }

    private func discoverBatteryLevel(_ id: UUID, failed: Bool) {
        guard let peripheral = pending[id]?.peripheral else { return }
        guard !failed, let service = batteryService(of: peripheral) else {
            complete(id, level: nil)
            return
        }
        peripheral.discoverCharacteristics([batteryLevelID], for: service)
    }

    private func readBatteryLevel(_ id: UUID, failed: Bool) {
        guard let peripheral = pending[id]?.peripheral else { return }
        guard !failed,
              let characteristic = batteryService(of: peripheral)?
                .characteristics?.first(where: { $0.uuid == batteryLevelID }) else {
            complete(id, level: nil)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    /// The standard Battery Service among the services discovered so far, if any.
    private func batteryService(of peripheral: CBPeripheral) -> CBService? {
        peripheral.services?.first { $0.uuid == batteryServiceID }
    }

    private func received(_ id: UUID, value: Data?, failed: Bool) {
        let level = failed ? nil : value.flatMap(BatteryLevelDecoder.percent(from:))
        complete(id, level: level)
    }
}

// MARK: - Delegates

// CoreBluetooth calls these on the main queue, which is the main actor. The CoreBluetooth objects
// are not Sendable, so only identifiers, data and error flags cross into the main actor; the
// peripherals themselves are looked up in `pending`.
extension BLEBatteryReader: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        MainActor.assumeIsolated { didUpdate(state: newState) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { discoverBatteryService(id) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { complete(id, level: nil) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        MainActor.assumeIsolated { complete(id, level: nil) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        let failed = error != nil
        MainActor.assumeIsolated { discoverBatteryLevel(id, failed: failed) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        let failed = error != nil
        MainActor.assumeIsolated { readBatteryLevel(id, failed: failed) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        let value = characteristic.value
        let failed = error != nil
        MainActor.assumeIsolated { received(id, value: value, failed: failed) }
    }
}
