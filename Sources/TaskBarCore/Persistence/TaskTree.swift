import Foundation

/// A task together with the titles of its ancestors, produced by flattening the tree.
public struct FlatTask: Equatable, Sendable {
    public var item: TaskItem
    /// IDs from the root down to (and including) the task itself.
    public var path: [UUID]
    /// Titles of the ancestors, root first. Empty for top-level tasks.
    public var ancestorTitles: [String]
}

/// Pure operations over the recursive task tree. Every function is side-effect free apart from
/// the `inout` collection it is handed, which keeps the whole tree logic unit-testable.
public enum TaskTree {
    // MARK: Lookup

    public static func find(_ id: UUID, in items: [TaskItem]) -> TaskItem? {
        for item in items {
            if item.id == id { return item }
            if let match = find(id, in: item.children) { return match }
        }
        return nil
    }

    /// The chain of tasks from the root down to `id`, or `nil` when it does not exist.
    public static func path(to id: UUID, in items: [TaskItem]) -> [TaskItem]? {
        for item in items {
            if item.id == id { return [item] }
            if let tail = path(to: id, in: item.children) { return [item] + tail }
        }
        return nil
    }

    /// The direct children of `parentID`, or the root list when `parentID` is `nil`.
    public static func children(of parentID: UUID?, in items: [TaskItem]) -> [TaskItem]? {
        guard let parentID else { return items }
        return find(parentID, in: items)?.children
    }

    // MARK: Mutation

    /// Applies `change` to the task with `id`. Returns `false` when the task is missing.
    @discardableResult
    public static func update(
        _ id: UUID,
        in items: inout [TaskItem],
        _ change: (inout TaskItem) -> Void
    ) -> Bool {
        for index in items.indices {
            if items[index].id == id {
                change(&items[index])
                return true
            }
            if update(id, in: &items[index].children, change) { return true }
        }
        return false
    }

    /// Inserts `item` under `parentID` (or at the root). `index` defaults to the end.
    @discardableResult
    public static func insert(
        _ item: TaskItem,
        under parentID: UUID?,
        at index: Int? = nil,
        in items: inout [TaskItem]
    ) -> Bool {
        withChildren(of: parentID, in: &items) { siblings -> Bool in
            let position = min(max(index ?? siblings.count, 0), siblings.count)
            siblings.insert(item, at: position)
            return true
        } ?? false
    }

    /// Removes the task with `id` (and its whole subtree) and returns it.
    @discardableResult
    public static func remove(_ id: UUID, from items: inout [TaskItem]) -> TaskItem? {
        if let index = items.firstIndex(where: { $0.id == id }) {
            return items.remove(at: index)
        }
        for index in items.indices {
            if let removed = remove(id, from: &items[index].children) { return removed }
        }
        return nil
    }

    /// Marks a task done or open, stamping the completion date.
    @discardableResult
    public static func setDone(
        _ id: UUID,
        _ isDone: Bool,
        at date: Date = Date(),
        in items: inout [TaskItem]
    ) -> Bool {
        update(id, in: &items) { task in
            task.isDone = isDone
            task.completedAt = isDone ? date : nil
            task.updatedAt = date
        }
    }

    /// Reorders the children of `parentID` so that the tasks named in `orderedIDs` appear in
    /// that order. Siblings not mentioned keep their slots, which lets callers reorder just the
    /// open tasks without disturbing completed ones.
    @discardableResult
    public static func reorder(
        under parentID: UUID?,
        orderedIDs: [UUID],
        in items: inout [TaskItem]
    ) -> Bool {
        withChildren(of: parentID, in: &items) { siblings -> Bool in
            let wanted = Set(orderedIDs)
            let byID = Dictionary(siblings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var queue = orderedIDs.compactMap { byID[$0] }[...]
            siblings = siblings.map { sibling in
                guard wanted.contains(sibling.id), let next = queue.popFirst() else { return sibling }
                return next
            }
            return true
        } ?? false
    }

    /// Deletes every completed direct child of `parentID`. Returns how many were removed.
    @discardableResult
    public static func removeCompleted(under parentID: UUID?, in items: inout [TaskItem]) -> Int {
        withChildren(of: parentID, in: &items) { siblings -> Int in
            let before = siblings.count
            siblings.removeAll(where: \.isDone)
            return before - siblings.count
        } ?? 0
    }

    // MARK: Traversal

    /// Depth-first list of every task with its ancestry, used by search.
    public static func flatten(_ items: [TaskItem]) -> [FlatTask] {
        var result: [FlatTask] = []
        func visit(_ nodes: [TaskItem], path: [UUID], titles: [String]) {
            for node in nodes {
                let nodePath = path + [node.id]
                result.append(FlatTask(item: node, path: nodePath, ancestorTitles: titles))
                visit(node.children, path: nodePath, titles: titles + [node.titleWithoutTags])
            }
        }
        visit(items, path: [], titles: [])
        return result
    }

    // MARK: Helpers

    private static func withChildren<Result>(
        of parentID: UUID?,
        in items: inout [TaskItem],
        _ body: (inout [TaskItem]) -> Result
    ) -> Result? {
        guard let parentID else { return body(&items) }
        for index in items.indices {
            if items[index].id == parentID { return body(&items[index].children) }
            if let result = withChildren(of: parentID, in: &items[index].children, body) {
                return result
            }
        }
        return nil
    }
}
