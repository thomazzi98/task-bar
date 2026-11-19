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
    /// The fields being edited right now. Escape undoes these before it closes the folder.
    private(set) var edit = LinkEditState()

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

    func isRenaming(_ folderID: UUID) -> Bool {
        edit.renamingFolderID == folderID
    }

    func isEditing(_ linkID: UUID) -> Bool {
        edit.editingLinkID == linkID
    }

    /// The text in the paste box of the open folder.
    var pasteDraft: String {
        get { edit.pasteDraft }
        set { edit.pasteDraft = newValue }
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard LinkBoard.folder(withID: id, in: folders) != nil else { return }
        openFolderID = id
    }

    /// Escape: undoes the innermost edit if there is one, otherwise closes the open folder. Returns
    /// `false` when there was nothing to undo or close, so Escape can close the popover.
    @discardableResult
    func stepBack() -> Bool {
        if edit.cancelInnermost() { return true }
        return closeFolder()
    }

    /// Returns to the home grid. `false` when already there.
    @discardableResult
    func closeFolder() -> Bool {
        guard openFolderID != nil else { return false }
        openFolderID = nil
        edit = LinkEditState()
        return true
    }

    // MARK: Folders

    /// Creates a folder in the next colour of the cycle and opens it. The colour cycles with the
    /// folder count, so each new folder differs from the one before it.
    @discardableResult
    func createFolder() -> UUID? {
        let colors = LinkFolder.colorNames
        let color = colors[folders.count % colors.count]
        var created: UUID?
        mutate { folders in
            created = LinkBoard.addFolder(named: "New folder", colorName: color, to: &folders)
            return created != nil
        }
        if let created { openFolderID = created }
        return created
    }

    /// Starts renaming a folder. The view gives its name field focus.
    func beginRename(_ folderID: UUID) {
        edit.renamingFolderID = folderID
    }

    /// Ends a rename and applies the name. Returns `false` when the name is blank, so the field can
    /// go back to the folder's name. A folder that is not being renamed is left alone.
    @discardableResult
    func commitRename(_ folderID: UUID, to name: String) -> Bool {
        guard edit.renamingFolderID == folderID else { return true }
        edit.renamingFolderID = nil
        return mutate { LinkBoard.renameFolder(folderID, to: name, in: &$0) }
    }

    func setColor(_ colorName: String, of id: UUID) {
        mutate { LinkBoard.setColor(colorName, of: id, in: &$0) }
    }

    func setSymbol(_ symbol: String, of id: UUID) {
        mutate { LinkBoard.setSymbol(symbol, of: id, in: &$0) }
    }

    func deleteFolder(_ id: UUID) {
        if openFolderID == id { closeFolder() }
        if edit.renamingFolderID == id { edit.renamingFolderID = nil }
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

    /// Starts editing a link in place.
    func beginEditingLink(_ linkID: UUID) {
        edit.editingLinkID = linkID
    }

    /// Saves a link's new title and address. The edit ends when the save succeeds.
    @discardableResult
    func updateLink(_ linkID: UUID, inFolder folderID: UUID, title: String, urlText: String) -> Bool {
        let saved = mutate { LinkBoard.updateLink(linkID, inFolder: folderID, title: title, urlText: urlText, in: &$0) }
        if saved, edit.editingLinkID == linkID { edit.editingLinkID = nil }
        return saved
    }

    func deleteLink(_ linkID: UUID, inFolder folderID: UUID) {
        if edit.editingLinkID == linkID { edit.editingLinkID = nil }
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
