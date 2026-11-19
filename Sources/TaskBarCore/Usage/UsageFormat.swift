import Foundation

/// Names of Claude models for the usage view.
public enum UsageFormat {
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
