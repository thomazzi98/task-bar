import Foundation
@testable import TaskBarCore

/// A scratch directory that tests create and remove themselves.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taskbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// App paths rooted inside this directory, mirroring the real layout.
    var paths: AppPaths {
        AppPaths(
            supportDirectory: url.appendingPathComponent("Application Support/TaskBar", isDirectory: true),
            claudeDirectory: url.appendingPathComponent(".claude", isDirectory: true)
        )
    }
}

/// A fixed instant, on a whole second so it survives an ISO 8601 round trip unchanged.
let referenceDate = Date(timeIntervalSince1970: 1_795_000_000)

/// Builders for the JSON Lines records Claude Code writes to session transcripts.
enum TranscriptFixture {
    static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    static func raw(_ text: String) -> Data {
        Data(text.utf8)
    }

    static func userPrompt(
        _ text: String,
        uuid: String = UUID().uuidString,
        timestamp: String = "2026-11-17T15:00:00.000Z",
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "type": "user",
            "uuid": uuid,
            "isSidechain": false,
            "timestamp": timestamp,
            "gitBranch": "main",
            "message": ["role": "user", "content": text]
        ]
        object.merge(extra) { _, new in new }
        return try line(object)
    }

    static func assistantText(
        _ text: String,
        messageID: String = "msg_text",
        stopReason: String = "end_turn",
        timestamp: String = "2026-11-17T15:00:05.000Z",
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "type": "assistant",
            "uuid": UUID().uuidString,
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "role": "assistant",
                "model": "claude-opus-5-5",
                "stop_reason": stopReason,
                "content": [["type": "text", "text": text]]
            ]
        ]
        object.merge(extra) { _, new in new }
        return try line(object)
    }

    static func toolUse(
        id: String,
        name: String,
        input: [String: Any] = [:],
        messageID: String = "msg_tool",
        timestamp: String = "2026-11-17T15:00:10.000Z"
    ) throws -> Data {
        try line([
            "type": "assistant",
            "uuid": UUID().uuidString,
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "id": messageID,
                "role": "assistant",
                "stop_reason": "tool_use",
                "content": [["type": "tool_use", "id": id, "name": name, "input": input]]
            ]
        ])
    }

    static func toolResult(for toolUseID: String, timestamp: String = "2026-11-17T15:00:12.000Z") throws -> Data {
        try line([
            "type": "user",
            "uuid": UUID().uuidString,
            "isSidechain": false,
            "timestamp": timestamp,
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": toolUseID, "content": "ok", "is_error": false]]
            ]
        ])
    }
}

extension Data {
    /// Joins JSON Lines records into the contents of a transcript file.
    static func jsonLines(_ lines: [Data]) -> Data {
        var data = Data()
        for line in lines {
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
