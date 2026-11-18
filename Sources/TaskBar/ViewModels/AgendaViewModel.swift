import Foundation
import Observation
import TaskBarCore

/// The upcoming events shown in the Calendar tab and in the "next event" strip.
@MainActor
@Observable
final class AgendaViewModel {
    private(set) var access: CalendarService.Access = .notDetermined
    private(set) var days: [AgendaDay] = []
    /// The event in progress or about to start, for the strip at the top of the popover.
    private(set) var nextEvent: AgendaEvent?
    /// Bumped once a minute while visible so relative labels ("in 12 min") stay current.
    private(set) var clock = Date()

    @ObservationIgnored private let service: CalendarService
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var events: [AgendaEvent] = []
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var isVisible = false

    /// How far ahead the agenda looks.
    private static let lookAheadDays = 7
    /// The strip only appears when the next event is this close.
    static let stripHorizon: TimeInterval = 45 * 60

    init(service: CalendarService, notifier: Notifier, settings: SettingsStore) {
        self.service = service
        self.notifier = notifier
        self.settings = settings
    }

    var isSupported: Bool { service.isSupported }

    /// Loads events if access was already granted. Never triggers a permission prompt.
    func start() {
        access = service.access
        service.observeChanges { [weak self] in
            self?.reload()
        }
        reload()
    }

    /// Asks for calendar access in response to an explicit user action.
    func connect() async {
        _ = await service.requestAccess()
        access = service.access
        reload()
    }

    func reload(now: Date = Date()) {
        access = service.access
        guard access == .granted else {
            apply(events: [], now: now)
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: Self.lookAheadDays, to: start) ?? now
        apply(events: service.events(from: start, to: end), now: now)
        rescheduleReminders()
    }

    /// Replaces the displayed events. Exposed for previews and snapshot rendering.
    func apply(events newEvents: [AgendaEvent], now: Date = Date(), access newAccess: CalendarService.Access? = nil) {
        if let newAccess { access = newAccess }
        events = newEvents
        clock = now
        // Events that already ended today are dropped; the rest keep their day grouping.
        let upcoming = newEvents.filter { !$0.hasEnded(at: now) || $0.isAllDay }
        days = AgendaBuilder.days(from: upcoming, now: now)
        nextEvent = AgendaBuilder.nextEvent(in: newEvents, now: now, horizon: Self.stripHorizon)
    }

    /// Keeps relative times fresh while the popover is open; idle otherwise.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        clockTask?.cancel()
        clockTask = nil
        guard visible else { return }

        reload()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.apply(events: self.events, now: Date())
            }
        }
    }

    func rescheduleReminders() {
        let minutes = settings.calendarReminderMinutes
        let upcoming = events
        Task { [notifier] in
            if minutes > 0 { await notifier.requestAuthorization() }
            await notifier.scheduleReminders(for: upcoming, minutesBefore: minutes)
        }
    }
}
