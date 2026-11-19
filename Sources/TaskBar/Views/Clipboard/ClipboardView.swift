import SwiftUI
import TaskBarCore

/// The Clipboard tab: recent copied text, pinned items first, with search.
struct ClipboardView: View {
    @Environment(ClipboardViewModel.self) private var clipboard
    @Environment(SettingsStore.self) private var settings

    @State private var query = ""

    var body: some View {
        let items = clipboard.items(matching: query)
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, Design.gutter)
                .padding(.top, 10)
                .padding(.bottom, 8)

            if !settings.keepsClipboardHistory {
                NoticeBanner(
                    text: "History is paused. Turn on “Keep clipboard history” in Settings to record copies.",
                    symbol: "pause.circle",
                    tint: .secondary
                )
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 6)
            }

            if let warning = clipboard.storageWarning {
                NoticeBanner(text: warning) { clipboard.dismissWarning() }
                    .padding(.horizontal, Design.gutter)
                    .padding(.bottom, 6)
            }

            if clipboard.itemCount == 0 {
                EmptyStateView(
                    symbol: "doc.on.clipboard",
                    title: "Nothing copied yet",
                    message: "Text you copy shows up here, ready to copy again. Passwords from password managers are skipped."
                )
            } else if items.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: "Nothing copied matches “\(query)”.")
            } else {
                list(items)
            }

            if clipboard.itemCount > 0 {
                Divider().opacity(0.6)
                ClipboardFooter(itemCount: clipboard.itemCount, unpinnedCount: clipboard.unpinnedCount)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            TextField("Search copies", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func list(_ items: [ClipboardItem]) -> some View {
        let pinned = items.filter(\.isPinned)
        let recent = items.filter { !$0.isPinned }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !pinned.isEmpty {
                    sectionTitle("Pinned")
                    ForEach(pinned) { ClipboardRow(item: $0) }
                }
                if !recent.isEmpty {
                    if !pinned.isEmpty { sectionTitle("Recent") }
                    ForEach(recent) { ClipboardRow(item: $0) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.4)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row

private struct ClipboardRow: View {
    let item: ClipboardItem

    @Environment(ClipboardViewModel.self) private var clipboard
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.text)
                .font(item.looksLikeCode ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            clipboard.copy(item.id)
            appState.showToast("Copied")
        }
        .hoverHighlight()
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }

    /// The age, which the hover buttons replace while the pointer is over the row.
    private var trailing: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 2) {
                ConfirmButton(symbol: "trash", confirmTitle: "Delete", help: "Delete this copy") {
                    clipboard.remove(item.id)
                }
                IconButton(
                    symbol: item.isPinned ? "pin.slash" : "pin",
                    help: item.isPinned ? "Unpin" : "Pin to the top",
                    isActive: item.isPinned,
                    tint: .orange
                ) {
                    clipboard.togglePin(item.id)
                }
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            TimelineView(.everyMinute) { context in
                HStack(spacing: 3) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange)
                    }
                    Text(item.age(now: context.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .opacity(isHovered ? 0 : 1)
        }
        .padding(.top, 1)
    }
}

// MARK: - Footer

private struct ClipboardFooter: View {
    let itemCount: Int
    let unpinnedCount: Int

    @Environment(ClipboardViewModel.self) private var clipboard
    @State private var isConfirmingClear = false
    @State private var disarmTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(itemCount) \(itemCount == 1 ? "copy" : "copies")")
            Spacer(minLength: 4)
            if isConfirmingClear {
                Text("Remove unpinned copies?")
                PillButton(title: "Clear", tint: .red, isProminent: true) { clear() }
                PillButton(title: "Cancel", tint: .secondary) { disarm() }
            } else if unpinnedCount > 0 {
                PillButton(title: "Clear", symbol: "trash", tint: .secondary) { arm() }
                    .help("Remove every copy except the pinned ones")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, Design.gutter)
        .frame(height: 30)
        .animation(.easeOut(duration: 0.12), value: isConfirmingClear)
        .onDisappear { disarm() }
    }

    /// The first click asks for confirmation. It is withdrawn after a few seconds.
    private func arm() {
        isConfirmingClear = true
        disarmTask?.cancel()
        disarmTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isConfirmingClear = false
        }
    }

    private func clear() {
        disarm()
        clipboard.clearUnpinned()
    }

    private func disarm() {
        disarmTask?.cancel()
        isConfirmingClear = false
    }
}
