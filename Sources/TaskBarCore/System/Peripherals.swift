import Foundation

/// The kind of a connected device. Picks its icon.
public enum PeripheralKind: String, Equatable, Sendable {
    case keyboard, mouse, trackpad, headphones, other

    /// Guesses the kind from `system_profiler`'s `device_minorType`, falling back to the name.
    public init(minorType: String?, name: String) {
        let text = "\(minorType ?? "") \(name)".lowercased()
        if ["airpods", "headphone", "headset", "earbud", "earphone", "beats"].contains(where: { text.contains($0) }) {
            self = .headphones
        } else if text.contains("trackpad") {
            self = .trackpad
        } else if text.contains("keyboard") {
            self = .keyboard
        } else if text.contains("mouse") {
            self = .mouse
        } else {
            self = .other
        }
    }
}

/// A connected device and the charge levels it reports, in percent.
public struct PeripheralDevice: Equatable, Identifiable, Sendable {
    public var name: String
    public var kind: PeripheralKind
    /// The single battery of keyboards, mice and trackpads.
    public var level: Int?
    /// Earbud and case levels, as reported for AirPods.
    public var leftLevel: Int?
    public var rightLevel: Int?
    public var caseLevel: Int?
    public var isCharging: Bool

    public init(
        name: String,
        kind: PeripheralKind,
        level: Int? = nil,
        leftLevel: Int? = nil,
        rightLevel: Int? = nil,
        caseLevel: Int? = nil,
        isCharging: Bool = false
    ) {
        self.name = name
        self.kind = kind
        self.level = level
        self.leftLevel = leftLevel
        self.rightLevel = rightLevel
        self.caseLevel = caseLevel
        self.isCharging = isCharging
    }

    /// Devices are matched across sources by name.
    public var id: String { name.lowercased() }

    /// How many battery levels the device reported. Used to pick the more detailed reading.
    public var levelCount: Int { allLevels.count }

    public var hasBattery: Bool { levelCount > 0 }

    /// The lowest reported level, which drives the warning colour.
    public var lowestLevel: Int? { allLevels.min() }

    private var allLevels: [Int] { [level, leftLevel, rightLevel, caseLevel].compactMap { $0 } }
}

/// Combines readings of the same device from different sources.
public enum PeripheralMerge {
    /// Matches devices by name and keeps the more detailed reading. On a tie the reading from
    /// `primary` wins. Devices without any battery level are left out.
    public static func merge(_ primary: [PeripheralDevice], _ secondary: [PeripheralDevice]) -> [PeripheralDevice] {
        var byID: [String: PeripheralDevice] = [:]
        for device in primary + secondary where device.hasBattery {
            guard let existing = byID[device.id] else {
                byID[device.id] = device
                continue
            }
            let (best, other) = device.levelCount > existing.levelCount ? (device, existing) : (existing, device)
            var merged = best
            if merged.kind == .other { merged.kind = other.kind }
            byID[device.id] = merged
        }
        return byID.values.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Decodes the GATT Battery Level characteristic (0x2A19), a single byte holding the percent.
public enum BatteryLevelDecoder {
    /// The first byte as a percent, clamped to 0...100. Empty data gives nil.
    public static func percent(from data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        return min(max(Int(byte), 0), 100)
    }
}

/// Reads battery levels out of `system_profiler SPBluetoothDataType -json`.
public enum PeripheralParser {
    /// The connected Bluetooth devices that report a battery. Other devices are skipped.
    public static func bluetoothDevices(profilerJSON data: Data) -> [PeripheralDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else {
            return []
        }
        var devices: [PeripheralDevice] = []
        for section in sections {
            // Each entry is a single-key dictionary: device name -> properties.
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let properties = value as? [String: Any] else { continue }
                    let device = PeripheralDevice(
                        name: name,
                        kind: PeripheralKind(minorType: properties["device_minorType"] as? String, name: name),
                        level: percent(properties["device_batteryLevelMain"]) ?? percent(properties["device_batteryLevel"]),
                        leftLevel: percent(properties["device_batteryLevelLeft"]),
                        rightLevel: percent(properties["device_batteryLevelRight"]),
                        caseLevel: percent(properties["device_batteryLevelCase"])
                    )
                    if device.hasBattery { devices.append(device) }
                }
            }
        }
        return devices
    }

    /// `"85%"` becomes 85, clamped to 0...100. Anything else, such as "Fully charged", gives nil.
    public static func percent(_ value: Any?) -> Int? {
        let number: Int?
        if let text = value as? String {
            number = Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        } else {
            number = value as? Int
        }
        return number.map { min(max($0, 0), 100) }
    }
}
