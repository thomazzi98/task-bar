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
    /// `primary` wins. Devices without any battery level are left out, but still lend their kind:
    /// a BLE keyboard reports its battery only over GATT, while `system_profiler` knows it is
    /// a keyboard.
    public static func merge(_ primary: [PeripheralDevice], _ secondary: [PeripheralDevice]) -> [PeripheralDevice] {
        var kinds: [String: PeripheralKind] = [:]
        var best: [String: PeripheralDevice] = [:]

        // Earlier devices win every tie, so `primary` comes first.
        for device in primary + secondary {
            if device.kind != .other, kinds[device.id] == nil {
                kinds[device.id] = device.kind
            }
            guard device.hasBattery else { continue }
            if let current = best[device.id], current.levelCount >= device.levelCount { continue }
            best[device.id] = device
        }

        return best.values
            .map { device in
                var merged = device
                if merged.kind == .other, let known = kinds[device.id] {
                    merged.kind = known
                }
                return merged
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
