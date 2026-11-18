import SwiftUI
import TaskBarCore

/// The Tasks tab: the top-level list, or the detail of the task drilled into.
struct TasksView: View {
    @Environment(TasksViewModel.self) private var tasks

    var body: some View {
        Group {
            if let task = tasks.currentTask {
                TaskDetailView(task: task)
                    // A fresh view per task resets local editing state when navigating.
                    .id(task.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                rootList
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: tasks.path)
    }

    private var rootList: some View {
        VStack(spacing: 0) {
            QuickAddField(placeholder: "New task", isPrimary: true) { title in
                tasks.add(title: title, under: nil)
            }
            .padding(.horizontal, Design.gutter)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let warning = tasks.storageWarning {
                NoticeBanner(text: warning) { tasks.dismissWarning() }
                    .padding(.horizontal, Design.gutter)
                    .padding(.bottom, 6)
            }

            TaskList(parentID: nil, emptyTitle: "Nothing to do", emptyMessage: "Type a task above and press Return.")
        }
    }
}

/// The open and completed children of one parent, with drag-to-reorder.
struct TaskList: View {
    let parentID: UUID?
    let emptyTitle: String
    var emptyMessage = ""

    @Environment(TasksViewModel.self) private var tasks
    @State private var showsCompleted = false

    var body: some View {
        let open = tasks.openChildren(of: parentID)
        let completed = tasks.completedChildren(of: parentID)

        if open.isEmpty, completed.isEmpty {
            EmptyStateView(symbol: "checklist", title: emptyTitle, message: emptyMessage)
        } else {
            List {
                ForEach(open) { task in
                    TaskRow(task: task).taskListRow()
                }
                .onMove { source, destination in
                    tasks.moveOpen(under: parentID, fromOffsets: source, toOffset: destination)
                }

                if !completed.isEmpty {
                    completedHeader(count: completed.count).taskListRow()
                    if showsCompleted {
                        ForEach(completed) { task in
                            TaskRow(task: task).taskListRow()
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 26)
        }
    }

    private func completedHeader(count: Int) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showsCompleted.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showsCompleted ? 90 : 0))
                    Text("Completed")
                    Text("\(count)").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
            if showsCompleted {
                Button("Clear") { tasks.clearCompleted(under: parentID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Delete all completed tasks in this list")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private extension View {
    /// Strips the default list chrome so rows look like the rest of the popover.
    func taskListRow() -> some View {
        listRowInsets(EdgeInsets(top: 0.5, leading: 6, bottom: 0.5, trailing: 6))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// One task in a list: checkbox, title, and a summary of what is inside it.
struct TaskRow: View {
    let task: TaskItem

    @Environment(TasksViewModel.self) private var tasks
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Checkbox(isOn: task.isDone) { tasks.toggleDone(task.id) }
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }

            VStack(alignment: .leading, spacing: 3) {
                Text(task.titleWithoutTags)
                    .font(.system(size: 13))
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                    .lineLimit(2)
                if hasMetadata { metadata }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { tasks.open(task.id) }
        .onHover { isHovered = $0 }
        .hoverHighlight()
        .contextMenu { menuItems }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var hasMetadata: Bool {
        task.priority != .none || !task.tags.isEmpty || !task.children.isEmpty || task.hasNotes
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if task.priority != .none {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Design.color(for: task.priority))
                    .help("\(task.priority.label) priority")
            }
            ForEach(task.tags.prefix(3), id: \.self) { tag in
                Chip(text: "#\(tag)", tint: .accentColor)
            }
            if !task.children.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "list.bullet.indent").font(.system(size: 9))
                    Text("\(task.doneChildCount)/\(task.children.count)").monospacedDigit()
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            if task.hasNotes {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help("Has notes")
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open") { tasks.open(task.id) }
        Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { tasks.toggleDone(task.id) }
        Menu("Priority") {
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
        }
        Divider()
        Button("Delete", role: .destructive) { tasks.delete(task.id) }
    }
}
