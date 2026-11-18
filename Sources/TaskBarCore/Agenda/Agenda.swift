import Foundation

/// A calendar event, detached from EventKit so the agenda logic stays testable.
public struct AgendaEvent: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarName: String
    /// Calendar colour as `#RRGGBB`.
    public var calendarColorHex: String?
    public var location: String?
    /// Video-call link found in the event, if any.
    public var meetingURL: URL?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarName: String = "",
        calendarColorHex: String? = nil,
        location: String? = nil,
        meetingURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.calendarColorHex = calendarColorHex
        self.location = location
        self.meetingURL = meetingURL
    }

    public func isInProgress(at date: Date) -> Bool {
        start <= date && date < end
    }

    public func hasEnded(at date: Date) -> Bool {
        end <= date
    }
}

/// The events of one calendar day.
public struct AgendaDay: Identifiable, Equatable, Sendable {
    /// Midnight at the start of the day.
    public var date: Date
    public var events: [AgendaEvent]

    public var id: Date { date }

    public init(date: Date, events: [AgendaEvent]) {
        self.date = date
        self.events = events
    }
}

public enum AgendaBuilder {
    /// Groups events by day, all-day events first and the rest chronologically. An event that
    /// began on an earlier day and is still running is listed under `now`'s day.
    public static func days(
        from events: [AgendaEvent],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [AgendaDay] {
        let today = calendar.startOfDay(for: now)
        let grouped = Dictionary(grouping: events) { event in
            max(calendar.startOfDay(for: event.start), today)
        }
        return grouped
            .map { day, events in
                AgendaDay(date: day, events: events.sorted { lhs, rhs in
                    if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                    if lhs.start != rhs.start { return lhs.start < rhs.start }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                })
            }
            .sorted { $0.date < $1.date }
    }

    /// The timed event to surface right now: the one in progress, otherwise the next to start
    /// within `horizon`. All-day events never qualify.
    public static func nextEvent(
        in events: [AgendaEvent],
        now: Date = Date(),
        horizon: TimeInterval = 12 * 3600
    ) -> AgendaEvent? {
        let timed = events.filter { !$0.isAllDay && !$0.hasEnded(at: now) }
        if let current = timed.filter({ $0.isInProgress(at: now) }).max(by: { $0.start < $1.start }) {
            return current
        }
        return timed
            .filter { $0.start > now && $0.start.timeIntervalSince(now) <= horizon }
            .min { $0.start < $1.start }
    }

    /// Short relative label such as "now", "in 12 min" or "in 3 h".
    public static func relativeStart(of event: AgendaEvent, now: Date = Date()) -> String {
        if event.isInProgress(at: now) { return "now" }
        let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 || hours >= 3 ? "in \(hours) h" : "in \(hours) h \(remainder) min"
    }
}

/// Finds a video-conference link among an event's free-text fields.
public enum MeetingLinkDetector {
    private static let meetingHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws", "gotomeeting.com", "around.co"
    ]

    public static func firstMeetingURL(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in detector.matches(in: text, options: [], range: range) {
                guard let url = match.url, isMeetingURL(url) else { continue }
                return url
            }
        }
        return nil
    }

    public static func isMeetingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
