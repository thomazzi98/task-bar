import SwiftUI
import TaskBarCore

/// The Notes tab: free-standing notes and prompt drafts, separate from tasks.
struct NotesView: View {
    @Environment(NotesViewModel.self) private var notes

    var body: some View {
        Group {
            if let note = notes.openNote {
                NoteEditorView(note: note)
                    .id(note.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                NotesListView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: notes.openNoteID)
    }
}

private struct NotesListView: View {
    @Environment(NotesViewModel.self) private var notes
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var notes = notes
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SegmentedControl(
                    options: NoteFilter.allCases.map { ($0, $0.label) },
                    selection: $notes.filter
                )

                Spacer()
                PillButton(title: "Prompt", symbol: "plus") { create(.prompt) }
                    .help("New prompt draft")
                PillButton(title: "Note", symbol: "plus", isProminent: true) { create(.note) }
                    .help("New note (⌘N)")
            }
            .padding(.horizontal, Design.gutter)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if let warning = notes.storageWarning {
                NoticeBanner(text: warning) { notes.dismissWarning() }
                    .padding(.horizontal, Design.gutter)
                    .padding(.bottom, 6)
            }

            let visible = notes.visibleNotes
            if visible.isEmpty {
                EmptyStateView(
                    symbol: notes.filter == .prompts ? "text.bubble" : "note.text",
                    title: notes.filter == .prompts ? "No prompts yet" : "No notes yet",
                    message: notes.filter == .prompts
                        ? "Dictate a rough idea, then let Refine prompt turn it into a clear prompt."
                        : "Capture ideas, links and meeting notes. Type or dictate."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { note in
                            NoteRow(note: note)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func create(_ kind: NoteKind) {
        notes.createNote(kind: kind)
        appState.requestPrimaryFocus()
    }
}

private struct NoteRow: View {
    let note: Note

    @Environment(NotesViewModel.self) private var notes
    @Environment(TasksViewModel.self) private var tasks
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                }
                Text(note.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if note.kind == .prompt {
                    Chip(text: "PROMPT", tint: .purple)
                }
                Spacer(minLength: 4)
                Text(note.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { notes.open(note.id) }
        .hoverHighlight()
        .contextMenu {
            Button(note.isPinned ? "Unpin" : "Pin") { notes.togglePinned(note.id) }
            Button("Copy Text") {
                Opener.copyToPasteboard(note.body)
                appState.showToast("Copied to clipboard")
            }
            Button("Convert to Task") { convertToTask() }
            Divider()
            Button("Delete", role: .destructive) { notes.delete(note.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func convertToTask() {
        tasks.insert(TaskItem(title: note.displayTitle, notes: note.body))
        notes.delete(note.id)
        appState.showToast("Moved to Tasks")
    }
}

/// The editor for one note or prompt draft.
private struct NoteEditorView: View {
    let note: Note

    @Environment(NotesViewModel.self) private var notes
    @Environment(TasksViewModel.self) private var tasks
    @Environment(AppState.self) private var appState
    @State private var title: String

    init(note: Note) {
        self.note = note
        _title = State(initialValue: note.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            BackBar(title: "Notes", onBack: { notes.closeEditor() }) {
                kindToggle
                IconButton(
                    symbol: note.isPinned ? "pin.fill" : "pin",
                    help: note.isPinned ? "Unpin" : "Pin to the top",
                    isActive: note.isPinned,
                    tint: .orange
                ) {
                    notes.togglePinned(note.id)
                }
                moreMenu
            }

            TextField(note.kind == .prompt ? "Prompt title" : "Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, Design.gutter)
                .padding(.bottom, 8)
                .onChange(of: title) { _, newValue in
                    notes.setTitle(note.id, to: newValue)
                }

            NotesEditorSection(
                targetID: "note-\(note.id.uuidString)",
                text: Binding(
                    get: { notes.note(withID: note.id)?.body ?? note.body },
                    set: { notes.setBody(note.id, to: $0) }
                ),
                style: PolishStyle(note.kind),
                placeholder: note.kind == .prompt
                    ? "Describe what you want the AI to do — type or dictate, then hit Refine prompt."
                    : "Start writing, or tap the mic to dictate.",
                isPrimary: true
            )
            .padding(.horizontal, Design.gutter)
            .padding(.bottom, 10)
        }
    }

    /// Switches between a plain note and a prompt draft, which changes how "Tidy up" rewrites.
    private var kindToggle: some View {
        let isPrompt = note.kind == .prompt
        return Button {
            notes.setKind(note.id, to: isPrompt ? .note : .prompt)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPrompt ? "text.bubble.fill" : "text.bubble")
                    .font(.system(size: 10.5))
                Text("Prompt").font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .foregroundStyle(isPrompt ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .background(Capsule().fill(isPrompt ? AnyShapeStyle(Color.purple) : AnyShapeStyle(Color.primary.opacity(0.07))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isPrompt
            ? "This is a prompt draft: Refine prompt rewrites it as a clear AI prompt"
            : "Mark as a prompt draft to refine it into an AI prompt")
    }

    private var moreMenu: some View {
        Menu {
            Button("Convert to Task") {
                let current = notes.note(withID: note.id) ?? note
                tasks.insert(TaskItem(title: current.displayTitle, notes: current.body))
                notes.delete(note.id)
                appState.showToast("Moved to Tasks")
            }
            Divider()
            Button("Delete Note", role: .destructive) { notes.delete(note.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
        }
        .plainMenu()
    }
}
