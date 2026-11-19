import SwiftUI
import TaskBarCore

/// The Links tab: a grid of folders on the home screen, and the links of one folder when open.
struct LinksView: View {
    @Environment(LinksViewModel.self) private var links

    var body: some View {
        Group {
            if let folder = links.openFolder {
                LinkFolderView(folder: folder)
                    .id(folder.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                LinkFolderGrid()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: links.openFolderID)
    }
}

/// The home screen: folder tiles, two per row, and a tile for a new folder.
private struct LinkFolderGrid: View {
    @Environment(LinksViewModel.self) private var links
    /// The tile whose name is being edited inline.
    @State private var renamingID: UUID?
    /// The folder waiting for the inline delete confirmation.
    @State private var deletingID: UUID?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)

    var body: some View {
        VStack(spacing: 0) {
            if let warning = links.storageWarning {
                NoticeBanner(text: warning) { links.dismissWarning() }
                    .padding(.horizontal, Design.gutter)
                    .padding(.top, 10)
            }

            if let folder = deletingFolder {
                InlineConfirmBar(
                    message: "Delete “\(folder.name)” and its \(LinkCount.text(folder.links.count))?",
                    confirmTitle: "Delete",
                    onConfirm: {
                        links.deleteFolder(folder.id)
                        deletingID = nil
                    },
                    onCancel: { deletingID = nil }
                )
                .padding(.horizontal, Design.gutter)
                .padding(.top, 8)
            }

            if links.folders.isEmpty {
                EmptyStateView(
                    symbol: "bookmark",
                    title: "No links yet",
                    message: "Create a folder for each topic, then paste links into it."
                )
                PillButton(title: "New folder", symbol: "plus", isProminent: true) {
                    links.createFolder()
                }
                .padding(.bottom, 14)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(links.folders) { folder in
                            LinkFolderTile(
                                folder: folder,
                                isRenaming: renamingID == folder.id,
                                onStartRename: { renamingID = folder.id },
                                onEndRename: { renamingID = nil },
                                onRequestDelete: { deletingID = folder.id }
                            )
                        }
                        newFolderTile
                    }
                    .padding(.horizontal, Design.gutter)
                    .padding(.top, 10)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private var deletingFolder: LinkFolder? {
        deletingID.flatMap { LinkBoard.folder(withID: $0, in: links.folders) }
    }

    private var newFolderTile: some View {
        Button {
            links.createFolder()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: LinkTile.minHeight)
            .background(
                RoundedRectangle(cornerRadius: LinkTile.radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One folder on the home grid: a coloured icon, the name and the number of links.
private struct LinkFolderTile: View {
    let folder: LinkFolder
    let isRenaming: Bool
    let onStartRename: () -> Void
    let onEndRename: () -> Void
    let onRequestDelete: () -> Void

    @Environment(LinksViewModel.self) private var links
    @State private var isHovered = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: folder.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinkPalette.color(folder.colorName))
                )

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Folder name", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit(commitRename)
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commitRename() }
                        }
                } else {
                    Text(folder.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Text(LinkCount.text(folder.links.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: LinkTile.minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: LinkTile.radius, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.09 : 0.05))
        )
        .contentShape(RoundedRectangle(cornerRadius: LinkTile.radius, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isRenaming else { return }
            links.open(folder.id)
        }
        .onChange(of: isRenaming, initial: true) { _, renaming in
            guard renaming else { return }
            draftName = folder.name
            nameFocused = true
        }
        .contextMenu {
            Button("Rename") { onStartRename() }
            FolderStyleMenus(folder: folder)
            Divider()
            Button("Delete", role: .destructive) { onRequestDelete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func commitRename() {
        guard isRenaming else { return }
        links.renameFolder(folder.id, to: draftName)
        onEndRename()
    }
}

/// Colour and icon submenus, shared by a folder tile's context menu and the folder's own menu.
struct FolderStyleMenus: View {
    let folder: LinkFolder

    @Environment(LinksViewModel.self) private var links

    var body: some View {
        Menu("Change color") {
            ForEach(LinkFolder.colorNames, id: \.self) { name in
                Button {
                    links.setColor(name, of: folder.id)
                } label: {
                    Label(LinkPalette.label(forColor: name), systemImage: name == folder.colorName ? "checkmark" : "circle")
                }
            }
        }
        Menu("Change icon") {
            ForEach(LinkFolder.symbolNames, id: \.self) { symbol in
                Button {
                    links.setSymbol(symbol, of: folder.id)
                } label: {
                    Label(LinkPalette.label(forSymbol: symbol), systemImage: symbol)
                }
            }
        }
    }
}

/// A confirmation row shown in place of a destructive action, such as deleting a folder.
struct InlineConfirmBar: View {
    let message: String
    let confirmTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            PillButton(title: "Cancel", tint: .secondary, action: onCancel)
            PillButton(title: confirmTitle, tint: .red, isProminent: true, action: onConfirm)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.08)))
    }
}

/// Shared tile metrics.
enum LinkTile {
    static let radius: CGFloat = 10
    static let minHeight: CGFloat = 86
}

/// Colours and labels for folder choices. Colour names come from `LinkFolder.colorNames`.
enum LinkPalette {
    static func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }

    static func label(forColor name: String) -> String {
        name.capitalized
    }

    static func label(forSymbol symbol: String) -> String {
        symbolLabels[symbol] ?? symbol
    }

    private static let symbolLabels: [String: String] = [
        "folder": "Folder",
        "star": "Favorites",
        "briefcase": "Work",
        "book": "Reading",
        "hammer": "Tools",
        "globe": "Web",
        "play.rectangle": "Videos",
        "cart": "Shopping",
        "graduationcap": "Learning",
        "person.2": "People",
    ]
}

/// "1 link" / "3 links".
enum LinkCount {
    static func text(_ count: Int) -> String {
        count == 1 ? "1 link" : "\(count) links"
    }
}
