import Foundation
import Testing
@testable import TaskBarCore

@Suite("Agenda")
struct AgendaTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// 2026-11-18 at the given UTC time.
    private func date(day: Int = 18, _ hour: Int, _ minute: Int = 0) -> Date {
        let components = DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)
        return calendar.date(from: components) ?? .distantPast
    }

    private func event(
        _ title: String,
        from start: Date,
        to end: Date,
        allDay: Bool = false
    ) -> AgendaEvent {
        AgendaEvent(id: title, title: title, start: start, end: end, isAllDay: allDay)
    }

    @Test func groupsEventsByDayWithAllDayFirst() {
        let events = [
            event("Lunch", from: date(12), to: date(13)),
            event("Standup", from: date(9), to: date(9, 15)),
            event("Holiday", from: date(0), to: date(day: 19, 0), allDay: true),
            event("Review", from: date(day: 19, 15), to: date(day: 19, 16))
        ]
        let days = AgendaBuilder.days(from: events, now: date(8), calendar: calendar)

        #expect(days.count == 2)
        #expect(days[0].date == date(0))
        #expect(days[0].events.map(\.title) == ["Holiday", "Standup", "Lunch"])
        #expect(days[1].events.map(\.title) == ["Review"])
    }

    @Test func listsAnOngoingMultiDayEventUnderToday() {
        let conference = event("Conference", from: date(day: 16, 9), to: date(day: 20, 18))
        let days = AgendaBuilder.days(from: [conference], now: date(10), calendar: calendar)
        #expect(days.map(\.date) == [date(0)])
    }

    @Test func picksTheEventInProgress() {
        let events = [
            event("Earlier", from: date(8), to: date(9)),
            event("Current", from: date(10), to: date(11)),
            event("Later", from: date(11), to: date(12))
        ]
        #expect(AgendaBuilder.nextEvent(in: events, now: date(10, 30))?.title == "Current")
    }

    @Test func picksTheNextUpcomingEventOtherwise() {
        let events = [
            event("Holiday", from: date(0), to: date(day: 19, 0), allDay: true),
            event("Later", from: date(15), to: date(16)),
            event("Soon", from: date(11), to: date(12)),
            event("Done", from: date(8), to: date(9))
        ]
        #expect(AgendaBuilder.nextEvent(in: events, now: date(10))?.title == "Soon")
    }

    @Test func ignoresEventsBeyondTheHorizon() {
        let tomorrow = event("Tomorrow", from: date(day: 19, 23), to: date(day: 20, 0))
        #expect(AgendaBuilder.nextEvent(in: [tomorrow], now: date(8)) == nil)
        #expect(AgendaBuilder.nextEvent(in: [tomorrow], now: date(8), horizon: 48 * 3600)?.title == "Tomorrow")
        #expect(AgendaBuilder.nextEvent(in: [], now: date(8)) == nil)
    }

    @Test func describesHowSoonAnEventStarts() {
        let meeting = event("Meeting", from: date(10), to: date(11))
        #expect(AgendaBuilder.relativeStart(of: meeting, now: date(10, 30)) == "now")
        #expect(AgendaBuilder.relativeStart(of: meeting, now: date(9, 48)) == "in 12 min")
        #expect(AgendaBuilder.relativeStart(of: meeting, now: date(9)) == "in 1 h")
        #expect(AgendaBuilder.relativeStart(of: meeting, now: date(8, 30)) == "in 1 h 30 min")
        #expect(AgendaBuilder.relativeStart(of: meeting, now: date(5, 45)) == "in 4 h")
    }

    @Test func findsMeetingLinksInEventText() {
        let notes = """
        Agenda: quarterly planning.
        Docs: https://docs.example.com/planning
        Join: https://meet.google.com/abc-defg-hij
        """
        #expect(MeetingLinkDetector.firstMeetingURL(in: [nil, "Room 4", notes])?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(
            MeetingLinkDetector.firstMeetingURL(in: ["https://acme.zoom.us/j/123456789?pwd=abc"])?.host
                == "acme.zoom.us"
        )
        #expect(MeetingLinkDetector.firstMeetingURL(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting"]) != nil)
        #expect(MeetingLinkDetector.firstMeetingURL(in: ["See https://example.com/agenda", nil, ""]) == nil)
    }

    @Test func doesNotTrustLookalikeHosts() throws {
        func isMeeting(_ string: String) throws -> Bool {
            MeetingLinkDetector.isMeetingURL(try #require(URL(string: string)))
        }
        #expect(try !isMeeting("https://notzoom.us/j/1"))
        #expect(try !isMeeting("https://zoom.us.evil.example/j/1"))
        #expect(try !isMeeting("ftp://zoom.us/j/1"))
        #expect(try isMeeting("https://zoom.us/j/1"))
    }
}
