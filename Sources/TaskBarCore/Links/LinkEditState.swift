import Foundation

/// The Links fields that can be mid-edit, and the order Escape undoes them in.
///
/// The popover handles Escape before SwiftUI sees it, so the view model must know what is being
/// typed. The innermost edit goes first: a rename, then a link being edited, then the paste box.
/// Only when none of them is active does Escape close the open folder.
public struct LinkEditState: Equatable, Sendable {
    /// The folder whose name field is active, on the home grid or in a folder's header.
    public var renamingFolderID: UUID?
    /// The link whose title and address are being edited in place.
    public var editingLinkID: UUID?
    /// Text typed into the paste box of the open folder.
    public var pasteDraft = ""

    public init() {}

    /// Cancels the innermost active edit. Returns `false` when nothing is being edited.
    @discardableResult
    public mutating func cancelInnermost() -> Bool {
        if renamingFolderID != nil {
            renamingFolderID = nil
        } else if editingLinkID != nil {
            editingLinkID = nil
        } else if !pasteDraft.isEmpty {
            pasteDraft = ""
        } else {
            return false
        }
        return true
    }
}
