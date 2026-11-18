import SwiftUI
import TaskBarCore

/// Inside a task: its title, a notes pad, and its subtasks — each of which opens the same way.
struct TaskDetailView: View {
    let task: TaskItem

    @Environment(TasksViewModel.self) private var tasks
    @Environment(NotesViewModel.self) private var notes
    @Environment(AppState.self) private var appState
    @State private var title: String
    @State private var isNotesExpanded = false

    init(task: TaskItem) {
        self.task = task
        _title = State(initialValue: task.title)
    }

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumb()
            header
            notesSection
            if !isNotesExpanded { subtasks }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Checkbox(isOn: task.isDone) { tasks.toggleDone(task.id) }
            TextField("Task title", text: $title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1...3)
                .strikethrough(task.isDone)
                .onChange(of: title) { _, newValue in
                    // An emptied field keeps the last real title rather than saving a blank one.
                    if !newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        tasks.rename(task.id, to: newValue)
                    }
                }
            priorityMenu
            moreMenu
        }
        .padding(.horizontal, Design.gutter)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private var priorityMenu: some View {
        Menu {
            ForEach(TaskPriority.allCases, id: \.self) { priority in
                Button {
                    tasks.setPriority(task.id, to: priority)
                } label: {
                    if task.priority == priority {
                        Label(priority.label, systemImage: "checkmark")
                    } else {
                        Text(priority.label)
                    }
                }
            }
        } label: {
            Image(systemName: task.priority == .none ? "flag" : "flag.fill")
                .font(.system(size: 12))
                .foregroundStyle(Design.color(for: task.priority))
        }
        .plainMenu()
        .help("Priority: \(task.priority.label)")
    }

    private var moreMenu: some View {
        Menu {
            Button("Copy as Note") {
                notes.insert(Note(title: task.title, body: task.notes))
                appState.showToast("Copied to Notes")
            }
            Divider()
            Button("Delete Task", role: .destructive) { tasks.delete(task.id) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .plainMenu()
    }

    // MARK: Notes

    private var notesSection: some View {
        VStack(spacing: 4) {
            HStack {
                sectionTitle("Notes")
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isNotesExpanded.toggle() }
                } label: {
                    Image(systemName: isNotesExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(isNotesExpanded ? "Show subtasks" : "Expand notes")
            }
            NotesEditorSection(
                targetID: "task-\(task.id.uuidString)",
                text: Binding(
                    get: { tasks.currentTask?.notes ?? task.notes },
                    set: { tasks.setNotes(task.id, to: $0) }
                ),
                placeholder: "Ideas, links, details… Markdown is supported."
            )
            .frame(minHeight: 110, maxHeight: isNotesExpanded ? .infinity : 170)
        }
        .padding(.horizontal, Design.gutter)
        .padding(.bottom, 8)
    }

    // MARK: Subtasks

    private var subtasks: some View {
        VStack(spacing: 0) {
            HStack {
                sectionTitle("Subtasks")
                if !task.children.isEmpty {
                    Text("\(task.doneChildCount)/\(task.children.count)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, Design.gutter)
            .padding(.bottom, 4)

            QuickAddField(placeholder: "New subtask") { title in
                tasks.add(title: title, under: task.id)
            }
            .padding(.horizontal, Design.gutter)
            .padding(.bottom, 4)

            TaskList(parentID: task.id, emptyTitle: "No subtasks", emptyMessage: "Break this task into smaller steps.")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .kerning(0.4)
    }
}

/// Shows where the current task sits in the tree and jumps to any ancestor.
private struct Breadcrumb: View {
    @Environment(TasksViewModel.self) private var tasks

    var body: some View {
        let chain = tasks.breadcrumb
        HStack(spacing: 2) {
            Button {
                tasks.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back (Esc)")

            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        crumb("Tasks", isCurrent: false) { tasks.goToRoot() }
                        ForEach(Array(chain.enumerated()), id: \.element.id) { index, ancestor in
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.quaternary)
                            crumb(ancestor.titleWithoutTags, isCurrent: index == chain.count - 1) {
                                tasks.open(ancestor.id)
                            }
                            .id(ancestor.id)
                        }
                    }
                }
                .onAppear {
                    // Deep paths overflow; keep the current task in view.
                    if let last = chain.last { scroller.scrollTo(last.id, anchor: .trailing) }
                }
            }
        }
        .padding(.horizontal, Design.gutter - 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func crumb(_ title: String, isCurrent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .frame(maxWidth: 150)
                .fixedSize()
                .padding(.vertical, 3)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}
