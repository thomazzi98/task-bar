import AppKit
import ServiceManagement
import TaskBarCore
import UserNotifications

/// Whether the process runs from a real `.app` bundle. Several system services (login items,
/// notifications, privacy prompts) only work for bundled apps, so they are skipped when the
/// binary is started directly, for example with `swift run`.
enum AppBundle {
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// Registers the app to start when the user logs in.
@MainActor
enum LoginItemManager {
    static var isSupported: Bool { AppBundle.isBundled }

    static var isEnabled: Bool {
        isSupported && SMAppService.mainApp.status == .enabled
    }

    /// Returns a description of the failure, or `nil` on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else { return "Launch at login needs the bundled app." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// Posts user notifications for agents that need attention and for upcoming events.
@MainActor
final class Notifier {
    private var isAuthorized = false

    var isSupported: Bool { AppBundle.isBundled }

    /// Asks for permission the first time it is needed. Returns whether posting is allowed.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isSupported else { return false }
        if isAuthorized { return true }
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        isAuthorized = granted
        return granted
    }

    func post(identifier: String, title: String, body: String) {
        guard isSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Replaces every scheduled event reminder with the given ones.
    func scheduleReminders(for events: [AgendaEvent], minutesBefore: Int, now: Date = Date()) async {
        guard isSupported else { return }
        let prefix = "taskbar.event."
        let center = UNUserNotificationCenter.current()

        // Clear the previous batch first, so a moved or deleted event leaves no stale reminder.
        let stale = await Self.pendingIdentifiers(withPrefix: prefix)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        guard minutesBefore > 0 else { return }

        for event in events where !event.isAllDay {
            let fireDate = event.start.addingTimeInterval(TimeInterval(-minutesBefore * 60))
            let delay = fireDate.timeIntervalSince(now)
            // Only the next day's worth: reminders are rebuilt whenever the calendar changes.
            guard delay > 1, delay < 24 * 3600 else { continue }

            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = "Starts in \(minutesBefore) min" + (event.location.map { " · \($0)" } ?? "")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: prefix + event.id, content: content, trigger: trigger))
        }
    }

    private nonisolated static func pendingIdentifiers(withPrefix prefix: String) async -> [String] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter { $0.hasPrefix(prefix) })
            }
        }
    }
}

/// Opens locations in other apps.
@MainActor
enum Opener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func revealInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
