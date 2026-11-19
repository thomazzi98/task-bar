import Foundation
import Observation
import TaskBarCore

/// State and actions for the clipboard history.
@MainActor
@Observable
final class ClipboardViewModel {
    private(set) var history: ClipboardHistory
    private(set) var storageWarning: String?

    @ObservationIgnored private let saver: DebouncedSaver<ClipboardDocument>

    init(store: JSONFileStore<ClipboardDocument>) {
        let outcome = store.loadOrRecover(default: ClipboardDocument())
        history = ClipboardHistory(items: outcome.document.items)
        saver = DebouncedSaver(store: store)
        if let quarantined = outcome.quarantinedFile {
            storageWarning = "The clipboard file was unreadable and was kept as \(quarantined.lastPathComponent)."
        }
        saver.onError = { [weak self] message in
            self?.storageWarning = "Could not save clipboard history: \(message)"
        }
    }

    var itemCount: Int { history.items.count }
    var unpinnedCount: Int { history.unpinnedCount }

    /// Matching items, pinned first.
    func items(matching query: String) -> [ClipboardItem] {
        history.search(query)
    }

    // MARK: Mutation

    /// Records text the monitor saw on the pasteboard.
    func capture(_ text: String, at date: Date = Date()) {
        guard history.insert(text, at: date) != nil else { return }
        persist()
    }

    /// Puts a past copy back on the pasteboard. The monitor then sees the change, and the copy
    /// moves to the top of the history.
    func copy(_ id: UUID) {
        guard let item = history.items.first(where: { $0.id == id }) else { return }
        Opener.copyToPasteboard(item.text)
    }

    func togglePin(_ id: UUID) {
        history.togglePin(id)
        persist()
    }

    func remove(_ id: UUID) {
        history.remove(id)
        persist()
    }

    func clearUnpinned() {
        history.clearUnpinned()
        persist()
    }

    func clearAll() {
        history.clearAll()
        persist()
    }

    func dismissWarning() {
        storageWarning = nil
    }

    func flush() {
        saver.flush()
    }

    // MARK: Private

    private func persist() {
        saver.schedule(ClipboardDocument(items: history.items))
    }
}
