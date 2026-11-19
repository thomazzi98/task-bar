import SwiftUI
import TaskBarCore

/// One folder opened: its name, a box to paste links into, and the links as a reorderable list.
struct LinkFolderView: View {
    let folder: LinkFolder

    @Environment(LinksViewModel.self) private var links
    @State private var name: String
    @State private var isConfirmingDelete = false
    @FocusState private var nameFocused: Bool

    init(folder: LinkFolder) {
        self.folder = folder
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            BackBar(title: "Links", onBack: { commitName(); links.closeFolder() }) {
                folderMenu
            }

            HStack(spacing: 7) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinkPalette.color(folder.colorName))
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit {
                        commitName()
                        nameFocused = false
                    }
                    .onChange(of: nameFocused) { _, focused in
                        if focused { links.beginRename(folder.id) } else { commitName() }
                    }
                    .onChange(of: links.edit.renamingFolderID) { _, renamingID in
                        // A cancelled rename (Escape) ends here: show the saved name and leave the field.
                        guard renamingID == nil else { return }
                        name = savedName
                        nameFocused = false
                    }
            }
            .padding(.horizontal, Design.gutter)
            .padding(.bottom, 8)

            StorageNotice(warning: links.storageWarning) { links.dismissWarning() }

            if isConfirmingDelete {
                InlineConfirmBar(
                    message: "Delete this folder and its \(LinkCount.text(folder.links.count))?",
                    confirmTitle: "Delete",
                    onConfirm: { links.deleteFolder(folder.id) },
                    onCancel: { isConfirmingDelete = false }
                )
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 8)
            }

            LinkPasteField(folderID: folder.id)
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 8)

            if folder.links.isEmpty {
                EmptyStateView(
                    symbol: "link",
                    title: "No links in this folder",
                    message: "Paste a link above and press Return."
                )
            } else {
                List {
                    ForEach(folder.links) { link in
                        LinkRow(link: link, folderID: folder.id, tint: LinkPalette.color(folder.colorName))
                    }
                    .onMove { source, destination in
                        links.moveLinks(inFolder: folder.id, fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 26)
            }
        }
        // A name typed but not yet committed is saved when the folder goes away.
        .onDisappear { commitName() }
    }

    /// The folder's name as the model has it, which is what a rejected or cancelled edit returns to.
    private var savedName: String {
        LinkBoard.folder(withID: folder.id, in: links.folders)?.name ?? folder.name
    }

    /// Ends the rename. A blank name is rejected and the field goes back to the saved name.
    private func commitName() {
        if !links.commitRename(folder.id, to: name) {
            name = savedName
        }
    }

    private var folderMenu: some View {
        Menu {
            FolderStyleMenus(folder: folder)
            Divider()
            Button("Delete Folder", role: .destructive) { isConfirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
        }
        .plainMenu()
    }
}
