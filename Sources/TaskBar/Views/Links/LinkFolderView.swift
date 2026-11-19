import SwiftUI
import TaskBarCore

/// One folder opened: its name, a box to paste links into, and the links as a reorderable list.
struct LinkFolderView: View {
    let folder: LinkFolder

    @Environment(LinksViewModel.self) private var links
    @State private var name: String
    @State private var isConfirmingDelete = false

    init(folder: LinkFolder) {
        self.folder = folder
        _name = State(initialValue: folder.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            BackBar(title: "Links", onBack: { links.closeFolder() }) {
                folderMenu
            }

            HStack(spacing: 7) {
                Image(systemName: folder.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinkPalette.color(folder.colorName))
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .onChange(of: name) { _, newValue in
                        links.renameFolder(folder.id, to: newValue)
                    }
            }
            .padding(.horizontal, Design.gutter)
            .padding(.bottom, 8)

            if let warning = links.storageWarning {
                NoticeBanner(text: warning) { links.dismissWarning() }
                    .padding(.horizontal, Design.gutter)
                    .padding(.bottom, 6)
            }

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

/// The box at the top of a folder. Return adds the pasted link; the title comes from its host.
private struct LinkPasteField: View {
    let folderID: UUID

    @Environment(LinksViewModel.self) private var links
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                TextField("Paste a link…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onChange(of: text) { _, _ in error = nil }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isFocused ? 0.07 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isFocused ? 0.45 : 0), lineWidth: 1)
            )

            if let error {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .padding(.leading, 2)
            }
        }
        .onChange(of: appState.focusRequest, initial: true) {
            if appState.isPanelVisible { isFocused = true }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if links.addLink(trimmed, toFolder: folderID) {
            text = ""
            isFocused = true
        } else {
            error = "That doesn’t look like a link."
        }
    }
}

/// One link in a folder. A click opens it; hover reveals Copy and Delete; Edit changes it in place.
private struct LinkRow: View {
    let link: LinkItem
    let folderID: UUID
    let tint: Color

    @Environment(LinksViewModel.self) private var links
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var editError: String?
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                content
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isEditing, let url = link.destination else { return }
            Opener.open(url)
        }
        .contextMenu {
            Button("Edit") { startEditing() }
            Button("Copy URL") { copyURL() }
            Divider()
            Button("Delete", role: .destructive) { links.deleteLink(link.id, inFolder: folderID) }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var content: some View {
        HStack(spacing: 9) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(host)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isHovered {
                IconButton(symbol: "doc.on.doc", help: "Copy URL") { copyURL() }
                ConfirmButton(symbol: "trash", confirmTitle: "Delete", help: "Delete link") {
                    links.deleteLink(link.id, inFolder: folderID)
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($titleFocused)
                .onSubmit(commitEdit)
            TextField("Address", text: $draftURL)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .onSubmit(commitEdit)
            if let editError {
                Text(editError)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        }
        .onExitCommand(perform: cancelEditing)
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(tint.opacity(0.16))
            if let letter = link.title.first(where: \.isLetter) {
                Text(String(letter).uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var host: String {
        link.destination.flatMap(LinkURL.displayHost(of:)) ?? link.url
    }

    private func startEditing() {
        draftTitle = link.title
        draftURL = link.url
        editError = nil
        isEditing = true
        titleFocused = true
    }

    private func commitEdit() {
        if links.updateLink(link.id, inFolder: folderID, title: draftTitle, urlText: draftURL) {
            isEditing = false
            editError = nil
        } else {
            editError = "That doesn’t look like a link."
        }
    }

    private func cancelEditing() {
        isEditing = false
        editError = nil
    }

    private func copyURL() {
        Opener.copyToPasteboard(link.url)
        appState.showToast("Link copied")
    }
}
