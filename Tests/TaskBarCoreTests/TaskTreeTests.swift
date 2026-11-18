import Foundation
import Testing
@testable import TaskBarCore

@Suite("Task tree")
struct TaskTreeTests {
    /// root
    /// ├── a
    /// │   ├── a1
    /// │   │   └── a1x
    /// │   └── a2 (done)
    /// └── b
    private struct IDs {
        let a, a1, a1x, a2, b: UUID
    }

    private func makeTree() -> (items: [TaskItem], ids: IDs) {
        let a1x = TaskItem(title: "a1x")
        let a1 = TaskItem(title: "a1", children: [a1x])
        let a2 = TaskItem(title: "a2", isDone: true)
        let a = TaskItem(title: "a", children: [a1, a2])
        let b = TaskItem(title: "b")
        return ([a, b], IDs(a: a.id, a1: a1.id, a1x: a1x.id, a2: a2.id, b: b.id))
    }

    @Test func findsTasksAtAnyDepth() throws {
        let (items, ids) = makeTree()
        #expect(TaskTree.find(ids.a1x, in: items)?.title == "a1x")
        #expect(TaskTree.find(UUID(), in: items) == nil)
    }

    @Test func buildsBreadcrumbPath() throws {
        let (items, ids) = makeTree()
        let path = try #require(TaskTree.path(to: ids.a1x, in: items))
        #expect(path.map(\.title) == ["a", "a1", "a1x"])
        #expect(TaskTree.path(to: UUID(), in: items) == nil)
    }

    @Test func insertsAtRootAndUnderParent() throws {
        var (items, ids) = makeTree()
        #expect(TaskTree.insert(TaskItem(title: "c"), under: nil, in: &items))
        #expect(items.map(\.title) == ["a", "b", "c"])

        let parent = ids.a1
        #expect(TaskTree.insert(TaskItem(title: "first"), under: parent, at: 0, in: &items))
        #expect(TaskTree.children(of: parent, in: items)?.map(\.title) == ["first", "a1x"])
    }

    @Test func insertUnderMissingParentFails() {
        var (items, _) = makeTree()
        #expect(!TaskTree.insert(TaskItem(title: "orphan"), under: UUID(), in: &items))
        #expect(TaskTree.flatten(items).count == 5)
    }

    @Test func insertClampsOutOfRangeIndex() {
        var items = [TaskItem(title: "only")]
        TaskTree.insert(TaskItem(title: "last"), under: nil, at: 99, in: &items)
        TaskTree.insert(TaskItem(title: "first"), under: nil, at: -5, in: &items)
        #expect(items.map(\.title) == ["first", "only", "last"])
    }

    @Test func updatesNestedTask() throws {
        var (items, ids) = makeTree()
        let target = ids.a1x
        #expect(TaskTree.update(target, in: &items) { $0.notes = "deep note" })
        #expect(TaskTree.find(target, in: items)?.notes == "deep note")
        #expect(!TaskTree.update(UUID(), in: &items) { $0.title = "nope" })
    }

    @Test func removesWholeSubtree() throws {
        var (items, ids) = makeTree()
        let removed = try #require(TaskTree.remove(ids.a1, from: &items))
        #expect(removed.children.map(\.title) == ["a1x"])
        #expect(TaskTree.find(ids.a1x, in: items) == nil)
        #expect(TaskTree.flatten(items).count == 3)
    }

    @Test func togglesCompletionAndStampsDate() throws {
        var (items, ids) = makeTree()
        let target = ids.b

        TaskTree.setDone(target, true, at: referenceDate, in: &items)
        var task = try #require(TaskTree.find(target, in: items))
        #expect(task.isDone)
        #expect(task.completedAt == referenceDate)

        TaskTree.setDone(target, false, at: referenceDate, in: &items)
        task = try #require(TaskTree.find(target, in: items))
        #expect(!task.isDone)
        #expect(task.completedAt == nil)
    }

    @Test func reordersOnlyTheNamedSiblings() {
        let open1 = TaskItem(title: "open1")
        let done = TaskItem(title: "done", isDone: true)
        let open2 = TaskItem(title: "open2")
        let open3 = TaskItem(title: "open3")
        var items = [open1, done, open2, open3]

        // Reorder the open tasks; the completed one keeps its slot.
        TaskTree.reorder(under: nil, orderedIDs: [open3.id, open1.id, open2.id], in: &items)
        #expect(items.map(\.title) == ["open3", "done", "open1", "open2"])
    }

    @Test func reordersChildrenOfANestedParent() throws {
        var (items, ids) = makeTree()
        let parent = ids.a
        let children = try #require(TaskTree.children(of: parent, in: items))
        TaskTree.reorder(under: parent, orderedIDs: children.reversed().map(\.id), in: &items)
        #expect(TaskTree.children(of: parent, in: items)?.map(\.title) == ["a2", "a1"])
    }

    @Test func removesCompletedChildren() throws {
        var (items, ids) = makeTree()
        let parent = ids.a
        #expect(TaskTree.removeCompleted(under: parent, in: &items) == 1)
        #expect(TaskTree.children(of: parent, in: items)?.map(\.title) == ["a1"])
        #expect(TaskTree.removeCompleted(under: nil, in: &items) == 0)
    }

    @Test func flattensWithAncestry() throws {
        let (items, ids) = makeTree()
        let flat = TaskTree.flatten(items)
        #expect(flat.map(\.item.title) == ["a", "a1", "a1x", "a2", "b"])

        let deepest = try #require(flat.first { $0.item.title == "a1x" })
        #expect(deepest.ancestorTitles == ["a", "a1"])
        #expect(deepest.path == [ids.a, ids.a1, ids.a1x])
    }

    @Test func extractsTagsFromTitle() {
        let task = TaskItem(title: "Ship release #Work #urgent-fix today #work #")
        #expect(task.tags == ["work", "urgent-fix"])
        #expect(task.titleWithoutTags == "Ship release today #")
    }

    @Test func titleMadeOnlyOfTagsStaysVisible() {
        #expect(TaskItem(title: "#inbox").titleWithoutTags == "#inbox")
    }

    @Test func reportsNotesAndChildProgress() {
        let (items, _) = makeTree()
        #expect(items[0].doneChildCount == 1)
        #expect(!items[0].hasNotes)
        #expect(TaskItem(title: "t", notes: "  \n").hasNotes == false)
        #expect(TaskItem(title: "t", notes: "x").hasNotes)
    }
}
