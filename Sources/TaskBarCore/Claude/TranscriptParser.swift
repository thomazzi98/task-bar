import Foundation

/// Turns the JSON Lines of a Claude Code session transcript into a `TranscriptSummary`.
///
/// Transcripts interleave conversation records (`user`, `assistant`) with a lot of bookkeeping
/// (`api-request`, `file-history-snapshot`, ...). Only the conversation and a couple of
/// metadata records matter here; everything else is skipped as cheaply as possible.
public enum TranscriptParser {
    /// Maximum number of conversation steps kept in a summary.
    public static let entryLimit = 60
    private static let textLimit = 4000

    public static func summarize(lines: [Data]) -> TranscriptSummary {
        var state = State()
        for line in lines {
            consume(line, into: &state)
        }
        return state.summary()
    }

    // MARK: Line handling

    private static let metadataPrefix = Data(#"{"type":""#.utf8)
    private static let relevantMetadataTypes: Set<String> = [
        "ai-title", "custom-title", "summary", "last-prompt", "user", "assistant"
    ]

    private static func consume(_ line: Data, into state: inout State) {
        // Bookkeeping records put `type` first. Reading it straight from the bytes lets us
        // skip multi-megabyte `api-request-blob` lines without decoding them.
        if line.starts(with: metadataPrefix) {
            let rest = line.dropFirst(metadataPrefix.count)
            guard let end = rest.firstIndex(of: UInt8(ascii: "\"")),
                  let type = String(data: rest[rest.startIndex..<end], encoding: .utf8),
                  relevantMetadataTypes.contains(type)
            else { return }
        }

        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "ai-title":
            if let title = nonEmpty(object["aiTitle"]) { state.aiTitle = title }
        case "custom-title":
            if let title = nonEmpty(object["customTitle"]) { state.customTitle = title }
        case "summary":
            if let title = nonEmpty(object["summary"]) { state.legacySummary = title }
        case "last-prompt":
            if let prompt = nonEmpty(object["lastPrompt"]) { state.lastPromptRecord = clipped(prompt) }
        case "user":
            consumeUser(object, into: &state)
        case "assistant":
            consumeAssistant(object, into: &state)
        default:
            break
        }
    }

    private static func consumeUser(_ object: [String: Any], into state: inout State) {
        guard isMainConversation(object), let message = object["message"] as? [String: Any] else { return }
        let uuid = object["uuid"] as? String ?? UUID().uuidString
        let timestamp = date(object["timestamp"])
        state.noteContext(of: object, timestamp: timestamp)

        let injectedBySystem = object["promptSource"] as? String == "system" || object["isMeta"] as? Bool == true

        if let text = message["content"] as? String {
            guard !injectedBySystem, let prompt = userVisibleText(text) else { return }
            state.appendPrompt(id: uuid, text: prompt, timestamp: timestamp)
            return
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for (index, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "tool_result":
                if let toolUseID = block["tool_use_id"] as? String {
                    state.resolveTool(toolUseID)
                }
            case "text":
                guard !injectedBySystem,
                      let text = block["text"] as? String,
                      let prompt = userVisibleText(text)
                else { continue }
                state.appendPrompt(id: "\(uuid)#\(index)", text: prompt, timestamp: timestamp)
            default:
                continue
            }
        }
    }

    private static func consumeAssistant(_ object: [String: Any], into state: inout State) {
        guard isMainConversation(object),
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]]
        else { return }

        let uuid = object["uuid"] as? String ?? UUID().uuidString
        let timestamp = date(object["timestamp"])
        let messageID = message["id"] as? String ?? uuid
        state.noteContext(of: object, timestamp: timestamp)
        if let model = nonEmpty(message["model"]) { state.model = model }
        if let stopReason = nonEmpty(message["stop_reason"]) { state.lastStopReason = stopReason }

        for (index, block) in blocks.enumerated() {
            switch block["type"] as? String {
            case "text":
                guard let text = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                state.appendAssistantText(id: "\(uuid)#\(index)", text: clipped(text), timestamp: timestamp)
            case "tool_use":
                guard let toolID = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let tool = PendingTool(id: toolID, name: name, summary: toolSummary(name: name, input: input))
                state.appendToolUse(tool, messageID: messageID, timestamp: timestamp)
            default:
                continue
            }
        }
    }

    // MARK: Field helpers

    /// Subagent ("sidechain") records belong to a nested conversation and are ignored.
    private static func isMainConversation(_ object: [String: Any]) -> Bool {
        object["isSidechain"] as? Bool != true
    }

    /// Text the person actually typed. Claude Code also stores machine-generated wrappers
    /// (`<task-notification>`, `<system-reminder>`, ...) as user content; those are dropped.
    private static func userVisibleText(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.hasPrefix("<") else { return nil }
        return clipped(text)
    }

    /// A short, human-readable description of a tool call.
    static func toolSummary(name: String, input: [String: Any]) -> String {
        func string(_ key: String) -> String? { nonEmpty(input[key]) }
        func firstLine(_ value: String?) -> String? {
            value?.split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
        }

        switch name {
        case "Bash":
            return firstLine(string("description")) ?? firstLine(string("command")) ?? ""
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            guard let path = string("file_path") ?? string("notebook_path") else { return "" }
            return URL(fileURLWithPath: path).lastPathComponent
        case "Grep", "Glob":
            return firstLine(string("pattern")) ?? ""
        case "Agent", "Task":
            return firstLine(string("description")) ?? ""
        case "WebFetch":
            return string("url").flatMap { URL(string: $0)?.host } ?? ""
        case "WebSearch":
            return firstLine(string("query")) ?? ""
        case "AskUserQuestion":
            let questions = input["questions"] as? [[String: Any]]
            return firstLine(questions?.first?["question"] as? String) ?? "Question for you"
        case "ExitPlanMode":
            return "Plan ready for review"
        default:
            return firstLine(string("description")) ?? ""
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clipped(_ text: String) -> String {
        text.count > textLimit ? String(text.prefix(textLimit)) + "…" : text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }

    // MARK: Accumulator

    private struct State {
        var aiTitle: String?
        var customTitle: String?
        var legacySummary: String?
        var lastPromptRecord: String?
        var lastUserPrompt: String?
        var lastAssistantText: String?
        var lastStopReason: String?
        var lastActivity: Date?
        var gitBranch: String?
        var model: String?
        var entries: [TranscriptEntry] = []

        /// Tool calls without a result yet, in the order they were issued.
        private var unresolved: [(tool: PendingTool, messageID: String, sequence: Int)] = []
        private var sequence = 0
        private var lastPromptSequence = -1
        private var lastAssistantMessageID: String?

        mutating func noteContext(of object: [String: Any], timestamp: Date?) {
            if let timestamp { lastActivity = max(lastActivity ?? timestamp, timestamp) }
            if let branch = object["gitBranch"] as? String, !branch.isEmpty { gitBranch = branch }
        }

        mutating func appendPrompt(id: String, text: String, timestamp: Date?) {
            sequence += 1
            lastPromptSequence = sequence
            lastUserPrompt = text
            append(TranscriptEntry(id: id, kind: .userPrompt, text: text, timestamp: timestamp))
        }

        mutating func appendAssistantText(id: String, text: String, timestamp: Date?) {
            sequence += 1
            lastAssistantText = text
            append(TranscriptEntry(id: id, kind: .assistantText, text: text, timestamp: timestamp))
        }

        mutating func appendToolUse(_ tool: PendingTool, messageID: String, timestamp: Date?) {
            sequence += 1
            lastAssistantMessageID = messageID
            unresolved.append((tool, messageID, sequence))
            append(TranscriptEntry(id: tool.id, kind: .toolUse(name: tool.name), text: tool.summary, timestamp: timestamp))
        }

        mutating func resolveTool(_ id: String) {
            sequence += 1
            unresolved.removeAll { $0.tool.id == id }
        }

        private mutating func append(_ entry: TranscriptEntry) {
            entries.append(entry)
            if entries.count > TranscriptParser.entryLimit {
                entries.removeFirst(entries.count - TranscriptParser.entryLimit)
            }
        }

        func summary() -> TranscriptSummary {
            // A tool call only counts as pending when it belongs to the latest assistant message
            // and nothing was typed after it; older unmatched calls were interrupted or their
            // results simply fall outside the part of the file that was read.
            let pending = unresolved
                .filter { $0.messageID == lastAssistantMessageID && $0.sequence > lastPromptSequence }
                .map(\.tool)

            return TranscriptSummary(
                title: customTitle ?? aiTitle ?? legacySummary,
                lastPrompt: lastUserPrompt ?? lastPromptRecord,
                lastAssistantText: lastAssistantText,
                entries: entries,
                pendingTools: pending,
                lastStopReason: lastStopReason,
                lastActivity: lastActivity,
                gitBranch: gitBranch,
                model: model
            )
        }
    }
}
