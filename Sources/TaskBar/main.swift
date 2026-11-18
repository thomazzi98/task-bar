import AppKit

// TaskBar lives only in the menu bar: no Dock icon, no main window.
let application = NSApplication.shared
let delegate = AppDelegate()

if let command = DeveloperCommand(arguments: CommandLine.arguments) {
    // Headless self-test commands, see `TaskBar --help`. They need a run loop but no UI.
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        exit(await command.run())
    }
} else {
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
}

application.run()
