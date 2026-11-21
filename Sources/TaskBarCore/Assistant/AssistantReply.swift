import Foundation

/// Splits an assistant answer into the text to show and the actions it proposes.
///
/// The model ends an answer with a strict block, one action per line:
///
///     <actions>
///     quit pid=1234 name="yes"
///     open-url url="http://localhost:3000"
///     </actions>
///
/// Only the four kinds in `ProposedAction` are kept. A line that is malformed, has an unknown kind,
/// repeats a field, carries an unexpected field, or fails validation is dropped on its own.
public enum AssistantReply {
    public static let maxActions = 5

    private static let openTag = "<actions>"
    private static let closeTag = "</actions>"

    /// `(text, actions)`: the answer without the block, and up to `maxActions` valid actions.
    public static func parse(_ raw: String) -> (text: String, actions: [ProposedAction]) {
        guard let open = raw.range(of: openTag) else {
            return (raw.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }

        let afterOpen = raw[open.upperBound...]
        let block: Substring
        let after: Substring
        if let close = afterOpen.range(of: closeTag) {
            block = afterOpen[..<close.lowerBound]
            after = afterOpen[close.upperBound...]
        } else {
            // An unclosed block still counts: its lines are parsed and nothing of it is shown.
            block = afterOpen
            after = ""
        }

        let text = [raw[..<open.lowerBound], after]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let actions = block
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
            .prefix(maxActions)
        return (text, Array(actions))
    }

    // MARK: Lines

    /// `kind key="value" key=value`. Values are quoted or bare; quoted values may hold spaces.
    static func parseLine(_ line: String) -> ProposedAction? {
        let linePattern = #/^\s*(?<kind>[a-z-]+)(?<fields>(?:\s+[a-z]+=(?:"[^"]*"|[^\s"]+))*)\s*$/#
        let fieldPattern = #/(?<key>[a-z]+)=(?:"(?<quoted>[^"]*)"|(?<bare>[^\s"]+))/#
        guard let match = line.wholeMatch(of: linePattern) else { return nil }

        var fields: [String: String] = [:]
        for field in match.output.fields.matches(of: fieldPattern) {
            let key = String(field.output.key)
            let value = String((field.output.quoted ?? field.output.bare) ?? "")
            // A repeated field is ambiguous, so the whole line is refused rather than guessed at.
            guard fields.updateValue(value, forKey: key) == nil else { return nil }
        }

        switch String(match.output.kind) {
        case "quit":
            return processAction(fields) { .quit(pid: $0, name: $1) }
        case "force-quit":
            return processAction(fields) { .forceQuit(pid: $0, name: $1) }
        case "stop-container":
            guard Set(fields.keys) == ["id", "name"],
                  let id = fields["id"], isContainerID(id),
                  let name = fields["name"], isSafeName(name)
            else { return nil }
            return .stopContainer(id: id, name: name)
        case "open-url":
            guard Set(fields.keys) == ["url"],
                  let raw = fields["url"], let url = URL(string: raw), ProposedAction.isWebURL(url)
            else { return nil }
            return .openURL(url)
        default:
            return nil
        }
    }

    private static func processAction(
        _ fields: [String: String],
        expecting make: (Int32, String) -> ProposedAction
    ) -> ProposedAction? {
        guard Set(fields.keys) == ["pid", "name"],
              let pidText = fields["pid"], let name = fields["name"],
              pidText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let pid = Int32(pidText), pid > 1,
              isSafeName(name)
        else { return nil }
        return make(pid, name)
    }

    // MARK: Validation

    /// Names come from the machine's own process and container lists, so only plain names are
    /// accepted. Quotes, semicolons, brackets of commands and line breaks never pass.
    static func isSafeName(_ name: String) -> Bool {
        let allowedPunctuation = Set(" ._-()+&'")
        return (1...120).contains(name.count)
            && name == name.trimmingCharacters(in: .whitespaces)
            && name.allSatisfy { $0.isLetter || $0.isNumber || allowedPunctuation.contains($0) }
    }

    /// Docker IDs are hexadecimal; a short prefix of one is accepted, and the runner must match it.
    static func isContainerID(_ id: String) -> Bool {
        (6...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
