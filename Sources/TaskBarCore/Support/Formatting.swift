import Foundation

/// Compact, locale-independent formatting shared by the UI and the tests.
public enum Formatting {
    /// `1.5 GB`, `820 MB`, `12 KB`. Uses binary units, like Activity Monitor's memory figures.
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        // A decimal only where it carries information: small megabyte values and gigabytes,
        // and never a pointless ".0" (16 GB, not 16.0 GB).
        let wantsDecimal = (unit == 2 && amount < 10) || (unit >= 3 && amount < 100)
        var number = String(format: "%.\(wantsDecimal ? 1 : 0)f", amount)
        if number.hasSuffix(".0") { number.removeLast(2) }
        return "\(number) \(units[unit])"
    }

    /// Transfer rate such as `1.2 MB/s`.
    public static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(bytesPerSecond, 0))) + "/s"
    }

    /// Percentage from a `0...1` fraction, e.g. `42%`.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Uptime such as `3d 4h` or `5h 12m`.
    public static func uptime(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval), 0) / 60
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}
