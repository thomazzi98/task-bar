import Foundation

/// Picks the dictation language when the user has not chosen one: the first of the user's
/// preferred languages that the speech engine supports.
public enum DictationLocaleResolver {
    /// Returns the supported identifier to use, or `nil` when none of the preferences match.
    ///
    /// For each preference in order, an exact match (ignoring case and `_`/`-` differences) wins;
    /// otherwise a supported locale in the same language is accepted, so `pt-PT` falls back to
    /// `pt-BR` when only the latter is available.
    public static func resolve(preferred: [String], supported: [String]) -> String? {
        for preference in preferred {
            let wanted = normalized(preference)
            guard !wanted.isEmpty else { continue }
            if let exact = supported.first(where: { normalized($0) == wanted }) {
                return exact
            }
            let language = languageCode(of: wanted)
            if let sameLanguage = supported.first(where: { languageCode(of: normalized($0)) == language }) {
                return sameLanguage
            }
        }
        return nil
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func languageCode(of normalizedIdentifier: String) -> String {
        String(normalizedIdentifier.prefix { $0 != "-" })
    }
}
