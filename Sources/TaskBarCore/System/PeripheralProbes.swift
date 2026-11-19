import Foundation
import IOKit

/// Reads battery levels from the IORegistry (fast, in-process) and from `system_profiler` (slow).
public enum PeripheralProbes {
    /// Keyboards and mice that report `BatteryPercent` directly to the IORegistry.
    public static func registryDevices() -> [PeripheralDevice] {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [PeripheralDevice] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let device = registryDevice(for: service) {
                devices.append(device)
            }
        }
        return devices
    }

    private static func registryDevice(for service: io_object_t) -> PeripheralDevice? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let level = dict["BatteryPercent"] as? Int,
              let name = dict["Product"] as? String, !name.isEmpty else {
            return nil
        }
        return PeripheralDevice(
            name: name,
            kind: PeripheralKind(minorType: nil, name: name),
            level: min(max(level, 0), 100),
            isCharging: dict["IsCharging"] as? Bool ?? false
        )
    }

    /// Connected Bluetooth devices with their battery levels. Takes about a second, so callers must
    /// throttle it. Returns nil when the tool fails or runs longer than `timeout`.
    public static func bluetoothDevices(timeout: TimeInterval) -> [PeripheralDevice]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }

        // Ends the tool if it hangs. Its output then closes, which unblocks the read below.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        return PeripheralParser.bluetoothDevices(profilerJSON: data)
    }
}
