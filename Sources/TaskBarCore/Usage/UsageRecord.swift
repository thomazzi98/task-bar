import Foundation

/// Token counts of one API message.
public struct TokenUsage: Equatable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheWrite: Int
    public var cacheRead: Int

    public static let zero = TokenUsage(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)

    public init(input: Int, output: Int, cacheWrite: Int, cacheRead: Int) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            cacheRead: lhs.cacheRead + rhs.cacheRead
        )
    }
}

/// One assistant message of a Claude Code transcript, with the usage it reported.
public struct UsageRecord: Equatable, Sendable {
    public let messageID: String
    public let model: String
    public let timestamp: Date
    public let project: String
    public let sessionID: String
    public let usage: TokenUsage

    public init(
        messageID: String,
        model: String,
        timestamp: Date,
        project: String,
        sessionID: String,
        usage: TokenUsage
    ) {
        self.messageID = messageID
        self.model = model
        self.timestamp = timestamp
        self.project = project
        self.sessionID = sessionID
        self.usage = usage
    }
}

/// Turns one transcript line into a usage record. Lines that are not assistant messages with
/// usage of a real model are rejected after decoding. The scanner pre-filters lines by their
/// bytes, so the decoder only sees the lines that can matter.
public struct UsageLineParser {
    // Formatters are costly to build, so they are shared. They are configured once here and only
    // ever read from afterwards, which is what makes sharing them across the scanner's threads safe.
    private nonisolated(unsafe) static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private nonisolated(unsafe) static let plainTimestamps = ISO8601DateFormatter()

    private let decoder = JSONDecoder()

    public init() {}

    /// The record for an assistant line with usage, or nil for anything else, including
    /// synthetic messages and malformed JSON.
    /// - Parameters:
    ///   - projectFolder: the project's folder name, used when `cwd` is missing.
    ///   - fallbackSessionID: the transcript's file name, used when `sessionId` is missing.
    public func record(from line: Data, projectFolder: String, fallbackSessionID: String) -> UsageRecord? {
        guard let decoded = try? decoder.decode(Line.self, from: line),
              decoded.type == "assistant",
              let message = decoded.message,
              let messageID = message.id,
              let model = message.model, model != "<synthetic>",
              let usage = message.usage,
              let stamp = decoded.timestamp.flatMap(parseDate)
        else { return nil }

        let project = decoded.cwd
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? projectFolder

        return UsageRecord(
            messageID: messageID,
            model: model,
            timestamp: stamp,
            project: project,
            sessionID: decoded.sessionId ?? fallbackSessionID,
            usage: TokenUsage(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0
            )
        )
    }

    private func parseDate(_ text: String) -> Date? {
        Self.timestamps.date(from: text) ?? Self.plainTimestamps.date(from: text)
    }

    /// Only the fields the usage view needs; everything else in the line is skipped.
    private struct Line: Decodable {
        let type: String?
        let timestamp: String?
        let cwd: String?
        let sessionId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let model: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheCreationInputTokens: Int?
            let cacheReadInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }
}
