import Foundation
import Observation
import TaskBarCore

/// State and actions for the hierarchical task list.
@MainActor
@Observable
final class TasksViewModel {
    private(set) var tasks: [TaskItem]
    /// IDs of the tasks drilled into, root first. Empty means the top-level list.
    private(set) var path: [UUID] = []
    /// Set when the data file could not be read or written.
    private(set) var storageWarning: String?

    @ObservationIgnored private let saver: DebouncedSaver<TaskDocument>

    init(store: JSONFileStore<TaskDocument>) {
        let outcome = store.loadOrRecover(default: TaskDocument())
        tasks = outcome.document.tasks
        saver = DebouncedSaver(store: store)
        if let quarantined = outcome.quarantinedFile {
            storageWarning = "The tasks file was unreadable and was kept as \(quarantined.lastPathComponent)."
        }
        saver.onError = { [weak self] message in
            self?.storageWarning = "Could not save tasks: \(message)"
        }
    }

    // MARK: Navigation

    var currentParentID: UUID? { path.last }

    /// The task currently drilled into, if any.
    var currentTask: TaskItem? {
        currentParentID.flatMap { TaskTree.find($0, in: tasks) }
    }

    /// The chain of tasks from the root to the current one.
    var breadcrumb: [TaskItem] {
        currentParentID.flatMap { TaskTree.path(to: $0, in: tasks) } ?? []
    }

    func open(_ id: UUID) {
        guard let chain = TaskTree.path(to: id, in: tasks) else { return }
        path = chain.map(\.id)
    }

    func navigate(toPath newPath: [UUID]) {
        guard let last = newPath.last else {
            path = []
            return
        }
        open(last)
    }

    @discardableResult
    func goBack() -> Bool {
        guard !path.isEmpty else { return false }
        path.removeLast()
        return true
    }

    func goToRoot() {
        path = []
    }

    // MARK: Reading

    func children(of parentID: UUID?) -> [TaskItem] {
        TaskTree.children(of: parentID, in: tasks) ?? []
    }

    func openChildren(of parentID: UUID?) -> [TaskItem] {
        children(of: parentID).filter { !$0.isDone }
    }

    func completedChildren(of parentID: UUID?) -> [TaskItem] {
        children(of: parentID)
            .filter(\.isDone)
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: Mutation

    @discardableResult
    func add(title: String, under parentID: UUID?) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TaskItem(title: trimmed)
        // New tasks go to the top, right under the field they were typed in, so the result
        // of pressing Return is always visible even in a long list.
        guard TaskTree.insert(item, under: parentID, at: 0, in: &tasks) else { return nil }
        persist()
        return item.id
    }

    /// Adds a fully formed task (used when converting a note).
    func insert(_ item: TaskItem, under parentID: UUID? = nil) {
        guard TaskTree.insert(item, under: parentID, at: 0, in: &tasks) else { return }
        persist()
    }

    func toggleDone(_ id: UUID) {
        guard let task = TaskTree.find(id, in: tasks) else { return }
        TaskTree.setDone(id, !task.isDone, in: &tasks)
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    func setNotes(_ id: UUID, to notes: String) {
        update(id) { $0.notes = notes }
    }

    func setPriority(_ id: UUID, to priority: TaskPriority) {
        update(id) { $0.priority = priority }
    }

    func delete(_ id: UUID) {
        // Leave the deleted task's screen (or any screen beneath it) before removing it.
        if let index = path.firstIndex(of: id) {
            path.removeSubrange(index...)
        }
        guard TaskTree.remove(id, from: &tasks) != nil else { return }
        persist()
    }

    /// Applies a drag-and-drop move within the open tasks of `parentID`.
    func moveOpen(under parentID: UUID?, fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = openChildren(of: parentID).map(\.id)
        let moving = source.map { ids[$0] }
        let insertionIndex = destination - source.filter { $0 < destination }.count
        ids.removeAll { moving.contains($0) }
        ids.insert(contentsOf: moving, at: min(max(insertionIndex, 0), ids.count))
        guard TaskTree.reorder(under: parentID, orderedIDs: ids, in: &tasks) else { return }
        persist()
    }

    func clearCompleted(under parentID: UUID?) {
        guard TaskTree.removeCompleted(under: parentID, in: &tasks) > 0 else { return }
        persist()
    }

    func dismissWarning() {
        storageWarning = nil
    }

    /// Writes any pending change to disk immediately.
    func flush() {
        saver.flush()
    }

    // MARK: Private

    private func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        let changed = TaskTree.update(id, in: &tasks) { task in
            change(&task)
            task.updatedAt = Date()
        }
        if changed { persist() }
    }

    private func persist() {
        saver.schedule(TaskDocument(tasks: tasks))
    }
}
