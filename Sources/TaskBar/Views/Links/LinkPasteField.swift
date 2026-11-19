import SwiftUI
import TaskBarCore

/// The box at the top of a folder. Return adds the pasted link; the title comes from its host.
struct LinkPasteField: View {
    let folderID: UUID

    @Environment(LinksViewModel.self) private var links
    @Environment(AppState.self) private var appState
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                TextField("Paste a link…", text: Bindable(links).pasteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onChange(of: links.pasteDraft) { _, _ in error = nil }
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
        let trimmed = links.pasteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if links.addLink(trimmed, toFolder: folderID) {
            links.pasteDraft = ""
            isFocused = true
        } else {
            error = LinkCopy.notALink
        }
    }
}
