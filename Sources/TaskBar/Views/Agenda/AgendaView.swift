import SwiftUI
import TaskBarCore

/// The Calendar tab: today and the coming days, read from the system calendars.
struct AgendaView: View {
    @Environment(AgendaViewModel.self) private var agenda
    @Environment(AppState.self) private var appState

    var body: some View {
        switch agenda.access {
        case .granted:
            if agenda.days.isEmpty {
                EmptyStateView(
                    symbol: "calendar",
                    title: "Nothing scheduled",
                    message: "No events in the next 7 days."
                )
            } else {
                eventList
            }
        case .notDetermined:
            connectPrompt
        case .denied:
            deniedPrompt
        }
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(agenda.days) { day in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dayTitle(day.date).uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Calendar.current.isDateInToday(day.date) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .kerning(0.4)
                            .padding(.horizontal, 8)
                        ForEach(day.events) { event in
                            AgendaEventRow(event: event, now: agenda.clock)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
        }
    }

    private func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if calendar.isDateInToday(date) { return "Today · \(weekday)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow · \(weekday)" }
        return weekday
    }

    private var connectPrompt: some View {
        VStack(spacing: 10) {
            EmptyStateView(
                symbol: "calendar.badge.plus",
                title: "See your day here",
                message: agenda.isSupported
                    ? "TaskBar reads the calendars already on this Mac. To include Google Calendar, add your Google account in System Settings › Internet Accounts."
                    : "Calendar access needs the bundled TaskBar.app (build it with `make app`)."
            )
            .frame(maxHeight: 190)

            if agenda.isSupported {
                PillButton(title: "Connect Calendar", symbol: "calendar", isProminent: true) {
                    Task {
                        // The system prompt takes focus; keep the popover open meanwhile.
                        await appState.holdingOpen { await agenda.connect() }
                    }
                }
                Button("Open Internet Accounts…") {
                    Opener.openSystemSettings(pane: "com.apple.Internet-Accounts-Settings.extension")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 30)
    }

    private var deniedPrompt: some View {
        VStack(spacing: 10) {
            EmptyStateView(
                symbol: "calendar.badge.exclamationmark",
                title: "Calendar access is off",
                message: "Allow TaskBar under Privacy & Security › Calendars to show your events."
            )
            .frame(maxHeight: 170)
            PillButton(title: "Open Privacy Settings", symbol: "lock.open") {
                Opener.openSystemSettings(pane: "com.apple.preference.security?Privacy_Calendars")
            }
            Spacer()
        }
        .padding(.top, 30)
    }
}

private struct AgendaEventRow: View {
    let event: AgendaEvent
    let now: Date

    var body: some View {
        let isLive = !event.isAllDay && event.isInProgress(at: now)
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: event.calendarColorHex) ?? .accentColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                    if isLive { Chip(text: "NOW", tint: .red) }
                }
                HStack(spacing: 6) {
                    Text(timeText).monospacedDigit()
                    if let location = event.location, event.meetingURL == nil {
                        Text("· \(location)").lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let url = event.meetingURL {
                PillButton(title: "Join", symbol: "video.fill", isProminent: isLive) {
                    Opener.open(url)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .hoverHighlight()
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }
}

/// A one-line reminder of the event in progress or about to start, shown above every tab.
struct NextEventStrip: View {
    let event: AgendaEvent
    let now: Date

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
                .font(.system(size: 10.5))
                .foregroundStyle(Color(hex: event.calendarColorHex) ?? .accentColor)
            Text(event.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Text(AgendaBuilder.relativeStart(of: event, now: now))
                .font(.system(size: 11.5))
                .foregroundStyle(event.isInProgress(at: now) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .monospacedDigit()
            Spacer(minLength: 4)
            if let url = event.meetingURL {
                PillButton(title: "Join", symbol: "video.fill", isProminent: true) { Opener.open(url) }
            }
        }
        .padding(.horizontal, Design.gutter)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        .onTapGesture { appState.select(.calendar) }
        .help("Open Calendar")
    }
}
