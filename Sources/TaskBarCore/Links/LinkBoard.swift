import Foundation

/// Edits to folders and links, as pure functions over a folder list.
///
/// Mutations return `true` when they changed something. When the target is missing or the input is
/// invalid they return `false` (`addFolder` returns `nil`) and leave the list untouched, so callers
/// can tell the user without checking first.
public enum LinkBoard {
    // MARK: Reading

    public static func folder(withID id: UUID, in folders: [LinkFolder]) -> LinkFolder? {
        folders.first { $0.id == id }
    }

    // MARK: Folders

    /// Appends a folder with the default icon. Returns its ID, or `nil` when the name is blank.
    @discardableResult
    public static func addFolder(named name: String, colorName: String = "blue", to folders: inout [LinkFolder]) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = LinkFolder(name: trimmed, colorName: colorName)
        folders.append(folder)
        return folder.id
    }

    @discardableResult
    public static func renameFolder(_ id: UUID, to name: String, in folders: inout [LinkFolder]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folderIndex(id, in: folders) else { return false }
        folders[index].name = trimmed
        return true
    }

    @discardableResult
    public static func setColor(_ colorName: String, of id: UUID, in folders: inout [LinkFolder]) -> Bool {
        guard LinkFolder.colorNames.contains(colorName), let index = folderIndex(id, in: folders) else {
            return false
        }
        folders[index].colorName = colorName
        return true
    }

    @discardableResult
    public static func setSymbol(_ symbol: String, of id: UUID, in folders: inout [LinkFolder]) -> Bool {
        guard LinkFolder.symbolNames.contains(symbol), let index = folderIndex(id, in: folders) else {
            return false
        }
        folders[index].symbol = symbol
        return true
    }

    /// Removes a folder together with its links.
    @discardableResult
    public static func deleteFolder(_ id: UUID, in folders: inout [LinkFolder]) -> Bool {
        guard let index = folderIndex(id, in: folders) else { return false }
        folders.remove(at: index)
        return true
    }

    /// Moves folders using the same offsets SwiftUI's `onMove` reports.
    @discardableResult
    public static func moveFolders(fromOffsets source: IndexSet, toOffset destination: Int, in folders: inout [LinkFolder]) -> Bool {
        move(&folders, fromOffsets: source, toOffset: destination)
    }

    // MARK: Links

    /// Adds a link to the end of a folder. The title is the host, and the text is normalized
    /// first: a bare address gets `https://`. Returns `false` when the text is not a link.
    @discardableResult
    public static func addLink(
        from input: String,
        toFolder id: UUID,
        in folders: inout [LinkFolder],
        now: Date = Date()
    ) -> Bool {
        guard let index = folderIndex(id, in: folders), let url = LinkURL.normalize(input) else {
            return false
        }
        let link = LinkItem(title: LinkURL.defaultTitle(for: url), url: url.absoluteString, createdAt: now)
        folders[index].links.append(link)
        return true
    }

    /// Replaces a link's title and address. A blank title falls back to the host.
    @discardableResult
    public static func updateLink(
        _ linkID: UUID,
        inFolder folderID: UUID,
        title: String,
        urlText: String,
        in folders: inout [LinkFolder]
    ) -> Bool {
        guard let folderIndex = folderIndex(folderID, in: folders),
              let linkIndex = linkIndex(linkID, in: folders[folderIndex].links),
              let url = LinkURL.normalize(urlText)
        else { return false }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        folders[folderIndex].links[linkIndex].title = trimmed.isEmpty ? LinkURL.defaultTitle(for: url) : trimmed
        folders[folderIndex].links[linkIndex].url = url.absoluteString
        return true
    }

    @discardableResult
    public static func deleteLink(_ linkID: UUID, inFolder folderID: UUID, in folders: inout [LinkFolder]) -> Bool {
        guard let folderIndex = folderIndex(folderID, in: folders),
              let linkIndex = linkIndex(linkID, in: folders[folderIndex].links)
        else { return false }
        folders[folderIndex].links.remove(at: linkIndex)
        return true
    }

    /// Reorders the links of one folder using SwiftUI `onMove` offsets.
    @discardableResult
    public static func moveLinks(
        inFolder folderID: UUID,
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        in folders: inout [LinkFolder]
    ) -> Bool {
        guard let index = folderIndex(folderID, in: folders) else { return false }
        return move(&folders[index].links, fromOffsets: source, toOffset: destination)
    }

    // MARK: Private

    private static func folderIndex(_ id: UUID, in folders: [LinkFolder]) -> Int? {
        folders.firstIndex { $0.id == id }
    }

    private static func linkIndex(_ id: UUID, in links: [LinkItem]) -> Int? {
        links.firstIndex { $0.id == id }
    }

    /// Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`: `destination` is an insertion
    /// point in the original array, so moving rows down lands them just before that index.
    @discardableResult
    private static func move<Element>(
        _ items: inout [Element],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> Bool {
        guard !source.isEmpty,
              source.allSatisfy({ $0 < items.count }),
              (0...items.count).contains(destination)
        else { return false }

        let moving = source.map { items[$0] }
        var remaining = items
        for index in source.reversed() {
            remaining.remove(at: index)
        }
        let insertion = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: insertion)
        items = remaining
        return true
    }
}
