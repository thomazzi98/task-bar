import AppKit
import TaskBarCore

/// Watches the general pasteboard and reports new copies.
///
/// macOS has no notification for clipboard changes, so the monitor compares `changeCount` every
/// half second. That read is nearly free; the contents are read only when the count moved. The
/// timer runs only while clipboard history is enabled, and it is the one piece of work that
/// runs while the popover is closed.
@MainActor
final class ClipboardMonitor {
    static let interval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let onCopy: (String) -> Void
    private var timer: Timer?
    private var lastChangeCount = 0

    init(pasteboard: NSPasteboard = .general, onCopy: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.onCopy = onCopy
    }

    func start() {
        guard timer == nil else { return }
        // Only copies made from now on count. Whatever is already on the pasteboard is old news.
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // A loose tolerance lets the system coalesce this wake-up with other timers.
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        guard let text = Self.copiedText(from: pasteboard) else { return }
        onCopy(text)
    }

    /// The text of the newest copy, or `nil` when it must not be recorded: a secret marked by a
    /// password manager, or content with neither text nor files.
    static func copiedText(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        guard !ClipboardPolicy.isConcealed(types: types) else { return nil }

        if let text = pasteboard.string(forType: .string) {
            return ClipboardPolicy.recordableText(text)
        }
        // Copied files are recorded as their paths, one per line.
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else { return nil }
        return ClipboardPolicy.recordableText(urls.map(\.path).joined(separator: "\n"))
    }
}
