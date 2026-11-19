import Foundation
import Testing
@testable import TaskBarCore

private func utc(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: iso)!
}

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// "Now" for every report test: noon on 19 November 2026, UTC.
private let now = utc("2026-11-19T12:00:00.000Z")

/// One assistant line as Claude Code writes it, with only the fields the usage view reads
/// plus a few it must ignore.
private func assistantLine(
    message id: String,
    model: String = "claude-opus-4-5-20251101",
    input: Int = 0,
    output: Int = 0,
    cacheWrite: Int = 0,
    cacheRead: Int = 0,
    timestamp: String = "2026-11-17T10:00:00.000Z",
    cwd: String? = "/Users/me/app",
    session: String? = "s1"
) -> String {
    var object: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "uuid": UUID().uuidString,
        "message": [
            "id": id,
            "model": model,
            "role": "assistant",
            "content": [["type": "text", "text": "hello"]],
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_creation_input_tokens": cacheWrite,
                "cache_read_input_tokens": cacheRead,
                "service_tier": "standard"
            ]
        ]
    ]
    if let cwd { object["cwd"] = cwd }
    if let session { object["sessionId"] = session }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func write(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
}

private func append(_ text: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
}

// MARK: - Pricing

@Suite("Usage pricing")
struct ModelPricingTests {
    @Test func matchesTheMostSpecificFamilyFirst() {
        #expect(ModelPricing.price(for: "claude-opus-5-5-20260101") == ModelPrice(input: 4, output: 20, cacheRead: 0.20))
        #expect(ModelPricing.price(for: "claude-opus-5") == ModelPrice(input: 5, output: 25, cacheRead: 0.50))
        #expect(ModelPricing.price(for: "claude-opus-4-5-20251101") == ModelPrice(input: 5, output: 25, cacheRead: 0.50))
        #expect(ModelPricing.price(for: "claude-opus-4-1") == ModelPrice(input: 15, output: 75, cacheRead: 1.50))
        #expect(ModelPricing.price(for: "claude-opus-4") == ModelPrice(input: 15, output: 75, cacheRead: 1.50))
        #expect(ModelPricing.price(for: "claude-sonnet-5-5") == ModelPrice(input: 2, output: 10, cacheRead: 0.10))
        #expect(ModelPricing.price(for: "claude-sonnet-5") == ModelPrice(input: 2, output: 10, cacheRead: 0.20))
        #expect(ModelPricing.price(for: "claude-sonnet-4-6") == ModelPrice(input: 3, output: 15, cacheRead: 0.30))
        #expect(ModelPricing.price(for: "claude-haiku-5-5") == ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01))
        #expect(ModelPricing.price(for: "claude-haiku-4-5-20251001") == ModelPrice(input: 1, output: 5, cacheRead: 0.10))
        #expect(ModelPricing.price(for: "claude-fable-5-2") == ModelPrice(input: 8, output: 40, cacheRead: 0.20))
        #expect(ModelPricing.price(for: "claude-fable-5-1") == ModelPrice(input: 10, output: 50, cacheRead: 1.00))
        #expect(ModelPricing.price(for: "claude-fable-5") == ModelPrice(input: 10, output: 50, cacheRead: 1.00))
    }

    @Test func unknownModelHasNoPriceAndNoCost() {
        #expect(ModelPricing.price(for: "<synthetic>") == nil)
        #expect(ModelPricing.price(for: "gpt-4o") == nil)
        #expect(ModelPricing.cost(of: TokenUsage(input: 10, output: 10, cacheWrite: 0, cacheRead: 0), model: "gpt-4o") == nil)
    }

    @Test func cacheWriteIsPricedAsOneAndAQuarterTimesInput() {
        let price = ModelPrice(input: 3, output: 15, cacheRead: 0.30)
        #expect(price.cacheWrite == 3.75)

        let usage = TokenUsage(input: 1_000_000, output: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
        // sonnet-4-5: 3 + 15 + 3.75 + 0.30 US$
        let cost = ModelPricing.cost(of: usage, model: "claude-sonnet-4-5")
        #expect(abs((cost ?? -1) - 22.05) < 1e-9)
    }
}

// MARK: - Line parsing

@Suite("Usage line parser")
struct UsageLineParserTests {
    private let parser = UsageLineParser()

    @Test func readsTheFieldsOfAnAssistantLine() throws {
        let line = Data(assistantLine(
            message: "msg_1", input: 10, output: 5, cacheWrite: 100, cacheRead: 1_000,
            timestamp: "2026-11-17T10:00:00.250Z", cwd: "/Users/me/projects/billing", session: "sess-A"
        ).utf8)

        let record = try #require(parser.record(from: line, projectFolder: "-Users-me-projects-billing", fallbackSessionID: "file"))
        #expect(record.messageID == "msg_1")
        #expect(record.model == "claude-opus-4-5-20251101")
        #expect(record.project == "billing")
        #expect(record.sessionID == "sess-A")
        #expect(record.usage == TokenUsage(input: 10, output: 5, cacheWrite: 100, cacheRead: 1_000))
        #expect(record.timestamp == utc("2026-11-17T10:00:00.250Z"))
    }

    @Test func fallsBackToTheFolderNameAndFileNameWhenFieldsAreMissing() throws {
        let line = Data(assistantLine(message: "msg_2", input: 1, cwd: nil, session: nil).utf8)

        let record = try #require(parser.record(from: line, projectFolder: "-Users-me-app", fallbackSessionID: "file-session"))
        #expect(record.project == "-Users-me-app")
        #expect(record.sessionID == "file-session")
    }

    @Test func rejectsLinesThatAreNotUsageOfARealModel() {
        let user = #"{"type":"user","timestamp":"2026-11-17T10:00:00.000Z","message":{"role":"user","content":"hi"}}"#
        let noUsage = #"{"type":"assistant","timestamp":"2026-11-17T10:00:00.000Z","message":{"id":"m","model":"claude-opus-4-5","content":[]}}"#
        let synthetic = assistantLine(message: "m_synthetic", model: "<synthetic>", input: 5)
        let malformed = #"{"type":"assistant","timestamp":"2026-11-17T10:00:00.000Z","message":{"id":"m_bad","usage":"#

        for text in [user, noUsage, synthetic, malformed, ""] {
            #expect(parser.record(from: Data(text.utf8), projectFolder: "p", fallbackSessionID: "s") == nil)
        }
    }
}

// MARK: - Aggregation

@Suite("Usage report")
struct UsageReportTests {
    /// Records spread over 40 days, one session per day, so every period has a known answer.
    private func records() -> [UsageRecord] {
        let days: [(stamp: String, id: String, session: String, model: String, tokens: Int)] = [
            ("2026-11-19T08:00:00.000Z", "today", "s-today", "claude-opus-4-5", 100),
            ("2026-11-17T09:00:00.000Z", "two-days", "s-week", "claude-sonnet-4-5", 200),
            ("2026-11-10T09:00:00.000Z", "ten-days", "s-month", "claude-sonnet-4-5", 300),
            ("2026-10-10T09:00:00.000Z", "forty-days", "s-old", "claude-haiku-4-5", 400)
        ]
        return days.map { day in
            UsageRecord(
                messageID: day.id,
                model: day.model,
                timestamp: utc(day.stamp),
                project: day.session == "s-old" ? "legacy" : "app",
                sessionID: day.session,
                usage: TokenUsage(input: day.tokens, output: 0, cacheWrite: 0, cacheRead: 0)
            )
        }
    }

    @Test func periodsIncludeTheRightDays() {
        let all = records()
        func messages(_ period: UsagePeriod) -> Int {
            UsageReport.make(records: all, period: period, now: now, calendar: utcCalendar).totals.messages
        }
        #expect(messages(.today) == 1)
        #expect(messages(.week) == 2)
        #expect(messages(.month) == 3)
        #expect(messages(.all) == 4)
    }

    @Test func totalsAndBreakdownsAreSortedAndPriced() {
        let report = UsageReport.make(records: records(), period: .all, now: now, calendar: utcCalendar)

        #expect(report.totals.usage.input == 1_000)
        // Sonnet 500 tokens, Haiku 400, Opus 100.
        #expect(report.byModel.map(\.name) == ["claude-sonnet-4-5", "claude-haiku-4-5", "claude-opus-4-5"])
        #expect(report.byProject.map(\.name) == ["app", "legacy"])
        #expect(report.byProject.first?.messages == 3)

        // Input prices per million tokens: opus-4-5 5 US$, haiku-4-5 1 US$, sonnet-4-5 3 US$.
        let opus = report.byModel.first { $0.name == "claude-opus-4-5" }
        #expect(abs((opus?.cost ?? -1) - 0.0005) < 1e-12)
        #expect(abs((report.totals.cost ?? -1) - 0.0024) < 1e-12)
    }

    @Test func unknownModelsContributeTokensButNoCost() {
        let record = UsageRecord(
            messageID: "x", model: "mystery-model", timestamp: now, project: "app", sessionID: "s",
            usage: TokenUsage(input: 500, output: 500, cacheWrite: 0, cacheRead: 0)
        )
        let report = UsageReport.make(records: [record], period: .all, now: now, calendar: utcCalendar)
        #expect(report.totals.usage.total == 1_000)
        #expect(report.totals.cost == nil)
        #expect(report.byModel.first?.cost == nil)
    }

    @Test func topSessionsKeepTheBusiestTen() {
        let sessions = (0..<12).map { index in
            UsageRecord(
                messageID: "m\(index)", model: "claude-haiku-4-5", timestamp: now, project: "app",
                sessionID: "session-\(index)", usage: TokenUsage(input: (index + 1) * 10, output: 0, cacheWrite: 0, cacheRead: 0)
            )
        }
        let report = UsageReport.make(records: sessions, period: .all, now: now, calendar: utcCalendar)

        #expect(report.topSessions.count == 10)
        #expect(report.topSessions.first?.sessionID == "session-11")
        #expect(report.topSessions.last?.sessionID == "session-2")
    }

    @Test func cacheHitRateUsesTheInputSideOnly() {
        let usage = TokenUsage(input: 100, output: 999, cacheWrite: 100, cacheRead: 800)
        let record = UsageRecord(messageID: "c", model: "claude-haiku-4-5", timestamp: now, project: "app", sessionID: "s", usage: usage)
        let report = UsageReport.make(records: [record], period: .all, now: now, calendar: utcCalendar)
        #expect(report.totals.cacheHitRate == 0.8)
    }

    @Test func dailyBucketsCoverTheChartWindow() {
        let report = UsageReport.make(records: records(), period: .week, now: now, calendar: utcCalendar)

        #expect(report.buckets.count == 7)
        #expect(!report.bucketsAreHours)
        // The last bucket is today; the 19th holds the 100-token message.
        #expect(report.buckets.last?.usage.total == 100)
        #expect(report.buckets.map(\.usage.total).reduce(0, +) == 300)
    }

    @Test func todayIsBucketedByHour() {
        let report = UsageReport.make(records: records(), period: .today, now: now, calendar: utcCalendar)

        #expect(report.buckets.count == 24)
        #expect(report.bucketsAreHours)
        #expect(report.buckets[8].usage.total == 100)
    }
}

// MARK: - Scanner

@Suite("Usage scanner")
struct UsageScannerTests {
    private let session = "-Users-me-app/s1.jsonl"

    @Test func countsEachMessageOnceAndSkipsBadLines() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let file = tmp.url.appendingPathComponent("projects/\(session)")
        try write([
            assistantLine(message: "m1", input: 10, output: 1, cacheWrite: 100, cacheRead: 1_000),
            // The same message streamed again with more output: only this copy counts.
            assistantLine(message: "m1", input: 10, output: 5, cacheWrite: 100, cacheRead: 1_000),
            assistantLine(message: "m_synth", model: "<synthetic>", input: 9_999),
            #"{"type":"assistant","message":{"id":"broken","usage":"#,
            assistantLine(message: "m3", model: "claude-sonnet-4-5", input: 20, output: 30, cwd: nil, session: nil)
        ], to: file)

        let scanner = UsageScanner(projectsDirectory: tmp.url.appendingPathComponent("projects"))
        let report = await scanner.report(for: .all, now: now, calendar: utcCalendar)

        #expect(report.totals.messages == 2)
        #expect(report.totals.usage == TokenUsage(input: 30, output: 35, cacheWrite: 100, cacheRead: 1_000))
        #expect(report.byProject.map(\.name).sorted() == ["-Users-me-app", "app"])
        // Both messages belong to the file's session, the second one by its file name.
        #expect(report.topSessions.map(\.sessionID) == ["s1"])
        #expect(report.topSessions.first?.messages == 2)
        // m1 on opus-4-5: 10*5 + 5*25 + 100*6.25 + 1000*0.5 = 1300 US$ per million.
        // m3 on sonnet-4-5: 20*3 + 30*15 = 510 US$ per million.
        #expect(abs((report.totals.cost ?? -1) - 0.00181) < 1e-12)
        #expect(report.bytesRead > 0)
    }

    @Test func readsOnlyAppendedBytesAndWaitsForCompleteLines() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let file = tmp.url.appendingPathComponent("projects/\(session)")
        try write([assistantLine(message: "m1", input: 10)], to: file)

        let scanner = UsageScanner(projectsDirectory: tmp.url.appendingPathComponent("projects"))
        _ = await scanner.report(for: .all, now: now, calendar: utcCalendar)

        // A complete line plus the start of another, which is still being written.
        let third = assistantLine(message: "m3", input: 40)
        let complete = assistantLine(message: "m2", input: 20) + "\n"
        let partial = String(third.prefix(60))
        try append(complete + partial, to: file)

        let afterAppend = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        #expect(afterAppend.totals.messages == 2)
        #expect(afterAppend.bytesRead == (complete + partial).utf8.count)

        // The rest of the partial line arrives.
        let remainder = String(third.dropFirst(60)) + "\n"
        try append(remainder, to: file)
        let completed = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        #expect(completed.totals.messages == 3)
        #expect(completed.totals.usage.input == 70)
    }

    @Test func unchangedFilesAreNotReadAgain() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        try write([assistantLine(message: "m1", input: 10)], to: tmp.url.appendingPathComponent("projects/\(session)"))

        let scanner = UsageScanner(projectsDirectory: tmp.url.appendingPathComponent("projects"))
        let first = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        let second = await scanner.report(for: .all, now: now, calendar: utcCalendar)

        #expect(first.bytesRead > 0)
        #expect(second.bytesRead == 0)
        #expect(second.totals == first.totals)
    }

    @Test func aRewrittenFileIsCountedFromItsNewContent() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let file = tmp.url.appendingPathComponent("projects/\(session)")
        try write([
            assistantLine(message: "old_1", input: 100),
            assistantLine(message: "old_2", input: 100)
        ], to: file)

        let scanner = UsageScanner(projectsDirectory: tmp.url.appendingPathComponent("projects"))
        _ = await scanner.report(for: .all, now: now, calendar: utcCalendar)

        try write([assistantLine(message: "new_1", input: 7)], to: file)
        let report = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        #expect(report.totals.messages == 1)
        #expect(report.totals.usage.input == 7)
    }

    @Test func deletedFilesDropOutOfTheTotals() async throws {
        let tmp = try TemporaryDirectory()
        defer { tmp.remove() }
        let file = tmp.url.appendingPathComponent("projects/\(session)")
        try write([assistantLine(message: "m1", input: 10)], to: file)

        let scanner = UsageScanner(projectsDirectory: tmp.url.appendingPathComponent("projects"))
        _ = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        try FileManager.default.removeItem(at: file)

        let report = await scanner.report(for: .all, now: now, calendar: utcCalendar)
        #expect(report.totals.messages == 0)
        #expect(report.totals.cost == nil)
    }
}

// MARK: - Formatting

@Suite("Usage formatting")
struct UsageFormatTests {
    @Test func compactNumbers() {
        #expect(UsageFormat.compact(987) == "987")
        #expect(UsageFormat.compact(1_000) == "1K")
        #expect(UsageFormat.compact(340_000) == "340K")
        #expect(UsageFormat.compact(1_200_000) == "1.2M")
        #expect(UsageFormat.compact(12_400_000) == "12M")
        #expect(UsageFormat.compact(3_400_000_000) == "3.4B")
    }

    @Test func money() {
        #expect(UsageFormat.money(nil) == "—")
        #expect(UsageFormat.money(1.234) == "US$ 1.23")
        #expect(UsageFormat.money(0) == "US$ 0.00")
    }

    @Test func modelNames() {
        #expect(UsageFormat.modelName("claude-opus-4-5-20251101") == "Opus 4.5")
        #expect(UsageFormat.modelName("claude-haiku-4-5") == "Haiku 4.5")
        #expect(UsageFormat.modelName("claude-fable-5") == "Fable 5")
        #expect(UsageFormat.modelName("<synthetic>") == "<synthetic>")
    }
}
