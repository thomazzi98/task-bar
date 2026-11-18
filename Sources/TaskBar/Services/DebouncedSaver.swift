import Foundation
import TaskBarCore

/// Coalesces rapid edits into a single disk write.
///
/// Typing a note mutates the document on every keystroke; the saver waits for a short pause
/// before writing, and `flush()` forces any pending write (on quit, or when the popover closes).
@MainActor
final class DebouncedSaver<Document: Codable & Sendable> {
    private let store: JSONFileStore<Document>
    private let delay: Duration
    private var pending: Document?
    private var task: Task<Void, Never>?
    /// Called with a description when a write fails.
    var onError: ((String) -> Void)?

    init(store: JSONFileStore<Document>, delay: Duration = .milliseconds(450)) {
        self.store = store
        self.delay = delay
    }

    func schedule(_ document: Document) {
        pending = document
        task?.cancel()
        task = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        guard let document = pending else { return }
        pending = nil
        do {
            try store.save(document)
        } catch {
            Log.storage.error("saving \(self.store.url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
        }
    }
}
