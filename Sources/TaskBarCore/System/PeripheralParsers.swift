import Foundation

/// Decodes the GATT Battery Level characteristic (0x2A19), a single byte holding the percent.
public enum BatteryLevelDecoder {
    /// The first byte as a percent, clamped to 0...100. Empty data gives nil.
    public static func percent(from data: Data) -> Int? {
        guard let byte = data.first else { return nil }
        return Int(byte).clamped(to: 0...100)
    }
}

/// Reads battery levels out of `system_profiler SPBluetoothDataType -json`.
public enum PeripheralParser {
    /// The connected Bluetooth devices, with whatever battery levels they report. Devices
    /// without a battery are kept so `PeripheralMerge` can learn their kind.
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
                    devices.append(device)
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
        return number?.clamped(to: 0...100)
    }
}
