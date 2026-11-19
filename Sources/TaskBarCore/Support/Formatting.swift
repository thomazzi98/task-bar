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

    /// `~/code/app` for a path inside the home folder. Other paths, including `/Users/rafael2/x`
    /// for home `/Users/rafael`, are returned unchanged.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Token counts such as `1.2M`, `340K`, `987`.
    public static func compact(_ value: Int) -> String {
        let number = Double(value)
        let (scaled, suffix): (Double, String)
        switch number {
        case 1_000_000_000...: (scaled, suffix) = (number / 1_000_000_000, "B")
        case 1_000_000...: (scaled, suffix) = (number / 1_000_000, "M")
        case 1_000...: (scaled, suffix) = (number / 1_000, "K")
        default: return String(value)
        }
        let text = scaled >= 10 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        let trimmed = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        return trimmed + suffix
    }

    /// Estimated US dollars such as `$1.23`, or an em dash when no price is known.
    public static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
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
