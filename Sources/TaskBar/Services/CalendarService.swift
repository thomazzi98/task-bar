import AppKit
import EventKit
import TaskBarCore

/// Reads events from the system calendar database through EventKit.
///
/// Any account added in System Settings > Internet Accounts (Google, iCloud, Exchange, ...)
/// shows up here, which is how Google Calendar is supported without API keys or OAuth setup.
@MainActor
final class CalendarService {
    enum Access: Equatable {
        case notDetermined, denied, granted
    }

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    /// Calendar access prompts require a usage description, which only a bundled app has.
    var isSupported: Bool { AppBundle.isBundled }

    var access: Access {
        guard isSupported else { return .denied }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted, .writeOnly: return .denied
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        guard isSupported else { return false }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Calls `handler` whenever any calendar changes, including after a sync.
    func observeChanges(_ handler: @escaping @MainActor () -> Void) {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    func events(from start: Date, to end: Date) -> [AgendaEvent] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.agendaEvent)
    }

    private static func agendaEvent(from event: EKEvent) -> AgendaEvent {
        let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgendaEvent(
            // Recurring events share an identifier, so the start date disambiguates occurrences.
            id: "\(event.eventIdentifier ?? UUID().uuidString)-\(Int(event.startDate.timeIntervalSince1970))",
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarName: event.calendar?.title ?? "",
            calendarColorHex: event.calendar?.color.flatMap(hexString),
            location: location?.isEmpty == false ? location : nil,
            meetingURL: MeetingLinkDetector.firstMeetingURL(in: [
                event.url?.absoluteString, event.location, event.notes
            ])
        )
    }

    private static func hexString(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded())
        )
    }
}
