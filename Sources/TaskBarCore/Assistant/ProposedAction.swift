import Foundation

/// An action Claude proposes in an answer. The app shows it as a button, and it runs only after
/// the user confirms. Only these four kinds exist: anything else is dropped when parsing.
public enum ProposedAction: Equatable, Sendable {
    case quit(pid: Int32, name: String)
    case forceQuit(pid: Int32, name: String)
    case stopContainer(id: String, name: String)
    case openURL(URL)

    /// The button label, such as "Quit yes (PID 1234)".
    public var title: String {
        switch self {
        case .quit(let pid, let name): "Quit \(name) (PID \(pid))"
        case .forceQuit(let pid, let name): "Force quit \(name) (PID \(pid))"
        case .stopContainer(_, let name): "Stop container \(name)"
        case .openURL(let url): "Open \(Self.hostAndPort(of: url))"
        }
    }

    /// Only web addresses may be opened, so a proposed link can never launch a file or an app.
    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// `localhost:3000` for a local dev server, the host alone otherwise.
    static func hostAndPort(of url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }
}
