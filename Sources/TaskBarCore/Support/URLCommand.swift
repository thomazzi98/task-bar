import Foundation

/// An action requested through the `taskbar://` URL scheme, for automation tools such as
/// Shortcuts, Raycast or a shell script:
///
///     open "taskbar://new-task?title=Call%20the%20bank"
///
/// Commands can only show the app or add content. Nothing destructive is reachable by URL,
/// since any app or web page is able to open one.
public enum URLCommand: Equatable, Sendable {
    case open
    case toggle
    case close
    /// Shows the tab with the given name (`tasks`, `notes`, `agents`, `calendar`, `system`).
    case showTab(String)
    case addTask(title: String)
    case addNote(text: String, isPrompt: Bool)

    /// A short name for logs that carries none of the user's text.
    public var name: String {
        switch self {
        case .open: "open"
        case .toggle: "toggle"
        case .close: "close"
        case .showTab: "tab"
        case .addTask: "new-task"
        case .addNote(_, let isPrompt): isPrompt ? "new-prompt" : "new-note"
        }
    }

    public static let scheme = "taskbar"
    /// Longest text accepted from a URL, to keep a malformed link from flooding the data file.
    static let maximumTextLength = 20_000

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // `taskbar://tab/notes` has the action in the host and the argument in the path.
        let action = (components.host ?? "").lowercased()
        let argument = components.path.split(separator: "/").first.map { String($0).lowercased() }
        func query(_ name: String) -> String? {
            let value = components.queryItems?.first { $0.name == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return String(value.prefix(Self.maximumTextLength))
        }

        switch action {
        case "open", "show":
            self = .open
        case "toggle":
            self = .toggle
        case "close", "hide":
            self = .close
        case "tab":
            guard let argument else { return nil }
            self = .showTab(argument)
        case "new-task":
            guard let title = query("title") else { return nil }
            self = .addTask(title: title)
        case "new-note", "new-prompt":
            guard let text = query("text") else { return nil }
            self = .addNote(text: text, isPrompt: action == "new-prompt" || query("kind") == "prompt")
        default:
            return nil
        }
    }
}
