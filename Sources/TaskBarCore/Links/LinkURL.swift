import Foundation

/// Turns pasted text into a link the app can open, and derives the title of a new link.
public enum LinkURL {
    /// Schemes that run script or embed content rather than opening a destination.
    static let refusedSchemes: Set<String> = ["javascript", "data", "vbscript"]

    /// The absolute URL for pasted text, or `nil` when it is empty or cannot be opened.
    ///
    /// Text without a scheme is taken as a web address, so `https://` is added. `http`,
    /// `https`, `file` and app schemes such as `vscode://` are kept as written.
    public static func normalize(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = hasScheme(trimmed) ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              !refusedSchemes.contains(scheme)
        else { return nil }

        switch scheme {
        case "http", "https":
            // A bare word such as "hello" is a typo, not a site: require a dotted host or localhost.
            guard let host = url.host, host == "localhost" || host.contains(".") else { return nil }
        case "file":
            guard !url.path.isEmpty else { return nil }
        default:
            guard url.host != nil || !url.path.isEmpty else { return nil }
        }
        return url
    }

    /// The title for a new link: its host without a leading `www.`. A URL without a host, such as
    /// `mailto:` or `file:`, is titled by its last path component, or by its whole address.
    public static func defaultTitle(for url: URL) -> String {
        if let host = displayHost(of: url) { return host }
        let name = url.lastPathComponent
        return name.isEmpty ? url.absoluteString : name
    }

    /// The host without a leading `www.`, or `nil` when the URL has no host.
    public static func displayHost(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased().hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// `scheme:` at the start of the text, such as `https://`, `mailto:` or `tel:`. A colon followed
    /// by a digit is a port, so `localhost:3000` and `example.com:8080` are hosts, not schemes.
    static func hasScheme(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:(?!\d)"#, options: .regularExpression) != nil
    }
}
