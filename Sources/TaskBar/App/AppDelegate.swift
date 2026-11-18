import AppKit
import TaskBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isAnotherInstanceRunning else {
            // A second copy would add a duplicate menu bar icon and fight over the hook spool.
            NSApp.terminate(nil)
            return
        }
        let environment = AppEnvironment()
        environment.start()
        self.environment = environment
    }

    /// Handles `taskbar://` links, including the one that launched the app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for command in urls.compactMap(URLCommand.init(url:)) {
            environment?.handle(command)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var isAnotherInstanceRunning: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != ownPID }
    }
}
