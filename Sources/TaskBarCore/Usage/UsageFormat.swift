import Foundation

/// Compact text for the usage view.
public enum UsageFormat {
    /// `1.2M`, `340K`, `987`.
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

    /// `US$ 1.23`, or an em dash when no price is known.
    public static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "US$ %.2f", value)
    }

    /// `claude-opus-4-5-20251101` becomes `Opus 4.5`. Ids in another shape are returned as is.
    public static func modelName(_ id: String) -> String {
        var parts = id.lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, ["opus", "sonnet", "haiku", "fable"].contains(family) else {
            return id
        }
        let version = parts.dropFirst()
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version.joined(separator: "."))"
    }
}
