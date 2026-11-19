import Foundation

/// The span of time a usage report covers.
public enum UsagePeriod: String, CaseIterable, Identifiable, Sendable {
    case today, week, month
    /// Every record on disk, but the chart still covers only the last 30 days, so it is
    /// labelled that way. Totals, breakdowns and sessions cover the whole history.
    case all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .all: "All"
        }
    }

    /// The first instant included, or nil for the whole history (`.all`). The 7 and 30 day
    /// periods include today, so they start six and twenty-nine days before it.
    public func start(now: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: now)
        switch self {
        case .today: return day
        case .week: return calendar.date(byAdding: .day, value: -6, to: day)
        case .month: return calendar.date(byAdding: .day, value: -29, to: day)
        case .all: return nil
        }
    }
}

/// Aggregated Claude Code consumption for one period.
public struct UsageReport: Equatable, Sendable {
    public struct Totals: Equatable, Sendable {
        public var usage: TokenUsage
        public var messages: Int
        /// Estimated cost of the messages whose model has a known price; nil when none does.
        public var cost: Double?

        /// Share of the input-side tokens that were served from the prompt cache.
        public var cacheHitRate: Double? {
            let inputSide = usage.input + usage.cacheRead + usage.cacheWrite
            guard inputSide > 0 else { return nil }
            return Double(usage.cacheRead) / Double(inputSide)
        }
    }

    /// A row of the model or project breakdown.
    public struct Breakdown: Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let usage: TokenUsage
        public let messages: Int
        public let cost: Double?
        public let lastActivity: Date?
    }

    public struct SessionRow: Identifiable, Equatable, Sendable {
        public var id: String { sessionID }
        public let sessionID: String
        public let project: String
        public let usage: TokenUsage
        public let messages: Int
        public let cost: Double?
        public let lastActivity: Date
    }

    /// One bar of the chart: an hour for "Today", otherwise a day.
    public struct Bucket: Identifiable, Equatable, Sendable {
        public var id: Int { index }
        public let index: Int
        public let start: Date
        public let usage: TokenUsage
    }

    public let period: UsagePeriod
    public let totals: Totals
    /// Sorted by total tokens, largest first.
    public let byModel: [Breakdown]
    /// Sorted by total tokens, largest first.
    public let byProject: [Breakdown]
    /// The ten busiest sessions, largest first.
    public let topSessions: [SessionRow]
    public let buckets: [Bucket]
    /// Whether the buckets are hours (true) or days (false).
    public let bucketsAreHours: Bool
    /// Bytes read from disk to produce this report. Zero when nothing had changed.
    public let bytesRead: Int

    /// Aggregates records that fall inside the period. Pure, so it can be tested without files.
    public static func make<Records: Sequence>(
        records: Records,
        period: UsagePeriod,
        now: Date,
        calendar: Calendar,
        bytesRead: Int = 0
    ) -> UsageReport where Records.Element == UsageRecord {
        let cutoff = period.start(now: now, calendar: calendar)
        let hourly = period == .today
        let chartStart = cutoff ?? calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
        let bucketStarts: [Date] = (0..<(hourly ? 24 : (period == .week ? 7 : 30))).compactMap { offset in
            calendar.date(byAdding: hourly ? .hour : .day, value: offset, to: chartStart)
        }
        let chartEnd = bucketStarts.last.flatMap { calendar.date(byAdding: hourly ? .hour : .day, value: 1, to: $0) }

        var totals = Accumulator()
        var models: [String: Accumulator] = [:]
        var projects: [String: Accumulator] = [:]
        var sessions: [String: Accumulator] = [:]
        var bucketTotals = [Accumulator](repeating: Accumulator(), count: bucketStarts.count)

        for record in records {
            if let cutoff, record.timestamp < cutoff { continue }
            let cost = ModelPricing.cost(of: record.usage, model: record.model)
            totals.add(record, cost: cost)
            models[record.model, default: Accumulator()].add(record, cost: cost)
            projects[record.project, default: Accumulator()].add(record, cost: cost)
            sessions[record.sessionID, default: Accumulator()].add(record, cost: cost)

            if let chartEnd, record.timestamp >= chartStart, record.timestamp < chartEnd,
               let index = bucketIndex(for: record.timestamp, starts: bucketStarts) {
                bucketTotals[index].add(record, cost: cost)
            }
        }

        let buckets = bucketStarts.enumerated().map { index, start in
            Bucket(index: index, start: start, usage: bucketTotals[index].usage)
        }

        return UsageReport(
            period: period,
            totals: Totals(usage: totals.usage, messages: totals.messages, cost: totals.cost),
            byModel: breakdowns(models),
            byProject: breakdowns(projects),
            topSessions: sessions
                .map { id, value in
                    SessionRow(
                        sessionID: id,
                        project: value.project,
                        usage: value.usage,
                        messages: value.messages,
                        cost: value.cost,
                        lastActivity: value.lastActivity ?? .distantPast
                    )
                }
                .sorted { largestFirst($0.usage.total, $1.usage.total, $0.sessionID, $1.sessionID) }
                .prefix(10)
                .map { $0 },
            buckets: buckets,
            bucketsAreHours: hourly,
            bytesRead: bytesRead
        )
    }

    private static func breakdowns(_ groups: [String: Accumulator]) -> [Breakdown] {
        groups
            .map { name, value in
                Breakdown(
                    name: name,
                    usage: value.usage,
                    messages: value.messages,
                    cost: value.cost,
                    lastActivity: value.lastActivity
                )
            }
            .sorted { largestFirst($0.usage.total, $1.usage.total, $0.name, $1.name) }
    }

    /// Orders by tokens, largest first, with the name as a stable tie-breaker.
    private static func largestFirst(_ lhsTotal: Int, _ rhsTotal: Int, _ lhsName: String, _ rhsName: String) -> Bool {
        lhsTotal != rhsTotal ? lhsTotal > rhsTotal : lhsName < rhsName
    }

    /// Index of the bucket that starts at or before `date`, given ascending starts.
    private static func bucketIndex(for date: Date, starts: [Date]) -> Int? {
        guard let first = starts.first, date >= first else { return nil }
        var index = starts.count - 1
        while index > 0, starts[index] > date {
            index -= 1
        }
        return index
    }

    /// Running sums for one group of records.
    private struct Accumulator {
        var usage = TokenUsage.zero
        var messages = 0
        var cost: Double?
        var lastActivity: Date?
        var project = ""

        mutating func add(_ record: UsageRecord, cost value: Double?) {
            usage = usage + record.usage
            messages += 1
            if let value {
                cost = (cost ?? 0) + value
            }
            // The project of the latest record wins; on a tie, the smaller name, so the result
            // does not depend on the order records arrive in.
            let isLatest = lastActivity.map { last in
                record.timestamp > last || (record.timestamp == last && record.project < project)
            } ?? true
            if isLatest {
                lastActivity = record.timestamp
                project = record.project
            }
        }
    }
}
