import Darwin
import Foundation

/// Facts about the Mac itself that the other samplers do not cover.
public enum MachineIdentity {
    /// The hardware model identifier, such as `MacBookPro18,3`.
    public static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The 1, 5 and 15 minute load averages. Empty when the system cannot report them.
    public static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        let count = getloadavg(&loads, 3)
        return count > 0 ? Array(loads.prefix(Int(count))) : []
    }
}
