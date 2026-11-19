import Foundation
import Observation
import TaskBarCore

/// State and actions for the Links tab: folders of bookmarks, and the folder currently open.
@MainActor
@Observable
final class LinksViewModel {
    private(set) var folders: [LinkFolder]
    /// The folder shown in detail, or `nil` on the home grid.
    private(set) var openFolderID: UUID?
    private(set) var storageWarning: String?

    @ObservationIgnored private let saver: DebouncedSaver<LinksDocument>

    init(store: JSONFileStore<LinksDocument>) {
        let outcome = store.loadOrRecover(default: LinksDocument())
        folders = outcome.document.folders
        saver = DebouncedSaver(store: store)
        if let quarantined = outcome.quarantinedFile {
            storageWarning = "The links file was unreadable and was kept as \(quarantined.lastPathComponent)."
        }
        saver.onError = { [weak self] message in
            self?.storageWarning = "Could not save links: \(message)"
        }
    }

    // MARK: Reading

    var openFolder: LinkFolder? {
        openFolderID.flatMap { LinkBoard.folder(withID: $0, in: folders) }
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard LinkBoard.folder(withID: id, in: folders) != nil else { return }
        openFolderID = id
    }

    /// Returns to the home grid. `false` when already there, so Escape can close the popover.
    @discardableResult
    func closeFolder() -> Bool {
        guard openFolderID != nil else { return false }
        openFolderID = nil
        return true
    }

    // MARK: Folders

    /// Creates a folder with a colour that differs from its neighbours, and opens it.
    @discardableResult
    func createFolder(name: String = "New folder") -> UUID? {
        let colors = LinkFolder.colorNames
        let color = colors[folders.count % colors.count]
        var created: UUID?
        mutate { folders in
            created = LinkBoard.addFolder(named: name, colorName: color, to: &folders)
            return created != nil
        }
        if let created { openFolderID = created }
        return created
    }

    func renameFolder(_ id: UUID, to name: String) {
        mutate { LinkBoard.renameFolder(id, to: name, in: &$0) }
    }

    func setColor(_ colorName: String, of id: UUID) {
        mutate { LinkBoard.setColor(colorName, of: id, in: &$0) }
    }

    func setSymbol(_ symbol: String, of id: UUID) {
        mutate { LinkBoard.setSymbol(symbol, of: id, in: &$0) }
    }

    func deleteFolder(_ id: UUID) {
        if openFolderID == id { openFolderID = nil }
        mutate { LinkBoard.deleteFolder(id, in: &$0) }
    }

    func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int) {
        mutate { LinkBoard.moveFolders(fromOffsets: source, toOffset: destination, in: &$0) }
    }

    // MARK: Links

    /// Adds a link typed or pasted into a folder. `false` when the text is not a link.
    @discardableResult
    func addLink(_ input: String, toFolder id: UUID) -> Bool {
        mutate { LinkBoard.addLink(from: input, toFolder: id, in: &$0) }
    }

    @discardableResult
    func updateLink(_ linkID: UUID, inFolder folderID: UUID, title: String, urlText: String) -> Bool {
        mutate { LinkBoard.updateLink(linkID, inFolder: folderID, title: title, urlText: urlText, in: &$0) }
    }

    func deleteLink(_ linkID: UUID, inFolder folderID: UUID) {
        mutate { LinkBoard.deleteLink(linkID, inFolder: folderID, in: &$0) }
    }

    func moveLinks(inFolder folderID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        mutate { LinkBoard.moveLinks(inFolder: folderID, fromOffsets: source, toOffset: destination, in: &$0) }
    }

    // MARK: Persistence

    func dismissWarning() {
        storageWarning = nil
    }

    func flush() {
        saver.flush()
    }

    // MARK: Private

    /// Applies an edit and saves when it changed something. Returns whether it did.
    @discardableResult
    private func mutate(_ change: (inout [LinkFolder]) -> Bool) -> Bool {
        var working = folders
        let changed = change(&working)
        guard changed else { return false }
        folders = working
        saver.schedule(LinksDocument(folders: folders))
        return true
    }
}
