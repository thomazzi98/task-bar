import SwiftUI
import TaskBarCore

/// One link in a folder. A click opens it; hovering reveals Copy and Delete; Edit changes it in place.
struct LinkRow: View {
    let link: LinkItem
    let folderID: UUID
    let tint: Color

    @Environment(LinksViewModel.self) private var links
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    @State private var draftTitle = ""
    @State private var draftURL = ""
    @State private var editError: String?
    @FocusState private var titleFocused: Bool

    private var isEditing: Bool { links.isEditing(link.id) }

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
            // Always laid out and only faded in, so hovering never shifts the row.
            HStack(spacing: 2) {
                IconButton(symbol: "doc.on.doc", help: "Copy URL") { copyURL() }
                ConfirmButton(symbol: "trash", confirmTitle: "Delete", help: "Delete link") {
                    links.deleteLink(link.id, inFolder: folderID)
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
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
        links.beginEditingLink(link.id)
        titleFocused = true
    }

    private func commitEdit() {
        if links.updateLink(link.id, inFolder: folderID, title: draftTitle, urlText: draftURL) {
            editError = nil
        } else {
            editError = LinkCopy.notALink
        }
    }

    private func copyURL() {
        Opener.copyToPasteboard(link.url)
        appState.showToast("Link copied")
    }
}
