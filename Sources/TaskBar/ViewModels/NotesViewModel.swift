import Foundation
import Observation
import TaskBarCore

/// Which notes the list shows.
enum NoteFilter: String, CaseIterable, Identifiable {
    case all, notes, prompts

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .notes: "Notes"
        case .prompts: "Prompts"
        }
    }

    func includes(_ note: Note) -> Bool {
        switch self {
        case .all: true
        case .notes: note.kind == .note
        case .prompts: note.kind == .prompt
        }
    }
}

/// State and actions for free-standing notes and prompt drafts.
@MainActor
@Observable
final class NotesViewModel {
    private(set) var notes: [Note]
    /// The note open in the editor, if any.
    private(set) var openNoteID: UUID?
    var filter: NoteFilter = .all
    private(set) var storageWarning: String?

    @ObservationIgnored private let saver: DebouncedSaver<NotesDocument>

    init(store: JSONFileStore<NotesDocument>) {
        let outcome = store.loadOrRecover(default: NotesDocument())
        notes = outcome.document.notes
        saver = DebouncedSaver(store: store)
        if let quarantined = outcome.quarantinedFile {
            storageWarning = "The notes file was unreadable and was kept as \(quarantined.lastPathComponent)."
        }
        saver.onError = { [weak self] message in
            self?.storageWarning = "Could not save notes: \(message)"
        }
    }

    // MARK: Reading

    var openNote: Note? {
        openNoteID.flatMap(note(withID:))
    }

    func note(withID id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    /// Pinned notes first, then most recently edited.
    var visibleNotes: [Note] {
        notes
            .filter(filter.includes)
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    // MARK: Navigation

    func open(_ id: UUID) {
        guard note(withID: id) != nil else { return }
        openNoteID = id
    }

    /// Closes the editor, discarding the note if nothing was ever written in it.
    @discardableResult
    func closeEditor() -> Bool {
        guard let id = openNoteID else { return false }
        openNoteID = nil
        if note(withID: id)?.isEmpty == true {
            notes.removeAll { $0.id == id }
            persist()
        }
        return true
    }

    // MARK: Mutation

    /// Creates an empty note and opens it in the editor.
    @discardableResult
    func createNote(kind: NoteKind = .note) -> UUID {
        let note = Note(kind: kind)
        notes.append(note)
        openNoteID = note.id
        persist()
        return note.id
    }

    func insert(_ note: Note) {
        notes.append(note)
        persist()
    }

    func setTitle(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    func setBody(_ id: UUID, to body: String) {
        update(id) { $0.body = body }
    }

    func setKind(_ id: UUID, to kind: NoteKind) {
        update(id) { $0.kind = kind }
    }

    func togglePinned(_ id: UUID) {
        // Pinning is not an edit: it must not bump the note to the top of "recent".
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].isPinned.toggle()
        persist()
    }

    func delete(_ id: UUID) {
        if openNoteID == id { openNoteID = nil }
        notes.removeAll { $0.id == id }
        persist()
    }

    func dismissWarning() {
        storageWarning = nil
    }

    func flush() {
        saver.flush()
    }

    // MARK: Private

    private func update(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[index])
        notes[index].updatedAt = Date()
        persist()
    }

    private func persist() {
        saver.schedule(NotesDocument(notes: notes))
    }
}
