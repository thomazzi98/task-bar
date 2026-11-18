import os

/// Unified-logging channels. Read them with Console.app or:
///
///     log stream --predicate 'subsystem == "io.github.thomazzi98.taskbar"' --level debug
///
/// Only states and counts are logged as public values. Anything typed by the user, such as
/// task titles, note text or prompts, is never logged.
enum Log {
    private static let subsystem = "io.github.thomazzi98.taskbar"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let agents = Logger(subsystem: subsystem, category: "agents")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let voice = Logger(subsystem: subsystem, category: "voice")
}
