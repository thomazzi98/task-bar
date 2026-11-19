import Foundation
import Testing
@testable import TaskBarCore

@Suite("Link URLs")
struct LinkURLTests {
    @Test func addsHttpsToBareAddresses() {
        #expect(LinkURL.normalize("example.com/path?q=1")?.absoluteString == "https://example.com/path?q=1")
        #expect(LinkURL.normalize("www.apple.com")?.absoluteString == "https://www.apple.com")
    }

    @Test func trimsWhitespaceAndKeepsExplicitSchemes() {
        #expect(LinkURL.normalize("  https://swift.org \n")?.absoluteString == "https://swift.org")
        #expect(LinkURL.normalize("http://neverssl.com")?.scheme == "http")
    }

    @Test func keepsFileAndAppSchemes() {
        #expect(LinkURL.normalize("file:///Users/me/notes.txt")?.scheme == "file")
        #expect(LinkURL.normalize("vscode://file/Users/me/app.swift")?.scheme == "vscode")
        #expect(LinkURL.normalize("obsidian://open?vault=work")?.scheme == "obsidian")
    }

    @Test func acceptsLocalhostWithPort() {
        #expect(LinkURL.normalize("localhost:3000")?.absoluteString == "https://localhost:3000")
    }

    @Test func treatsHostAndPortAsAnAddressNotAScheme() {
        #expect(LinkURL.normalize("example.com:8080")?.absoluteString == "https://example.com:8080")
        #expect(LinkURL.normalize("example.com:8080/docs")?.absoluteString == "https://example.com:8080/docs")
    }

    @Test func keepsMailAndPhoneSchemes() {
        // Without this, a pasted "mailto:" became "https://mailto:…".
        #expect(LinkURL.normalize("mailto:a@b.com")?.absoluteString == "mailto:a@b.com")
        #expect(LinkURL.normalize("tel:+5511999999999")?.absoluteString == "tel:+5511999999999")
    }

    @Test func rejectsEmptyAndUnusableInput() {
        #expect(LinkURL.normalize("") == nil)
        #expect(LinkURL.normalize("   ") == nil)
        #expect(LinkURL.normalize("https://") == nil)
        #expect(LinkURL.normalize("hello") == nil)
        #expect(LinkURL.normalize("https://exa mple.com") == nil)
    }

    @Test func refusesScriptSchemes() {
        #expect(LinkURL.normalize("javascript:alert(1)") == nil)
        #expect(LinkURL.normalize("data://text/html,hi") == nil)
    }

    @Test func titleIsTheHostWithoutWww() throws {
        let github = try #require(LinkURL.normalize("https://www.github.com/rafael/repo"))
        #expect(LinkURL.defaultTitle(for: github) == "github.com")
        let docs = try #require(LinkURL.normalize("https://docs.swift.org"))
        #expect(LinkURL.defaultTitle(for: docs) == "docs.swift.org")
        let file = try #require(LinkURL.normalize("file:///Users/me/notes.txt"))
        #expect(LinkURL.defaultTitle(for: file) == "notes.txt")
    }
}

@Suite("Link edits")
struct LinkEditStateTests {
    @Test func escapeUndoesTheInnermostEditFirst() {
        var edit = LinkEditState()
        edit.pasteDraft = "example.com"
        edit.editingLinkID = UUID()
        edit.renamingFolderID = UUID()

        // The results are captured first: a mutating call cannot sit directly inside #expect.
        let renameCancelled = edit.cancelInnermost()
        #expect(renameCancelled)
        #expect(edit.renamingFolderID == nil)
        #expect(edit.editingLinkID != nil)

        let editCancelled = edit.cancelInnermost()
        #expect(editCancelled)
        #expect(edit.editingLinkID == nil)
        #expect(edit.pasteDraft == "example.com")

        let pasteCleared = edit.cancelInnermost()
        #expect(pasteCleared)
        #expect(edit.pasteDraft.isEmpty)

        // Nothing left to undo: Escape falls through to closing the folder.
        let nothingLeft = edit.cancelInnermost()
        #expect(!nothingLeft)
    }
}

@Suite("Link board")
struct LinkBoardTests {
    private func makeBoard() -> (folders: [LinkFolder], work: UUID, a: UUID, b: UUID, c: UUID) {
        let a = LinkItem(title: "a", url: "https://a.com")
        let b = LinkItem(title: "b", url: "https://b.com")
        let c = LinkItem(title: "c", url: "https://c.com")
        let work = LinkFolder(name: "Work", links: [a, b, c])
        let home = LinkFolder(name: "Home")
        return ([work, home], work.id, a.id, b.id, c.id)
    }

    @Test func addsFoldersAndRejectsBlankNames() {
        var folders: [LinkFolder] = []
        let id = LinkBoard.addFolder(named: "  Reading ", colorName: "teal", to: &folders)
        #expect(folders.count == 1)
        #expect(folders.first?.id == id)
        #expect(folders.first?.name == "Reading")
        #expect(folders.first?.colorName == "teal")
        #expect(LinkBoard.addFolder(named: "   ", to: &folders) == nil)
        #expect(folders.count == 1)
    }

    @Test func renamesAndRestylesFolders() {
        var (folders, work, _, _, _) = makeBoard()
        #expect(LinkBoard.renameFolder(work, to: " Office ", in: &folders))
        #expect(folders[0].name == "Office")
        #expect(!LinkBoard.renameFolder(work, to: "  ", in: &folders))
        #expect(folders[0].name == "Office")

        #expect(LinkBoard.setColor("purple", of: work, in: &folders))
        #expect(!LinkBoard.setColor("neon", of: work, in: &folders))
        #expect(folders[0].colorName == "purple")

        #expect(LinkBoard.setSymbol("cart", of: work, in: &folders))
        #expect(!LinkBoard.setSymbol("not.a.symbol", of: work, in: &folders))
        #expect(folders[0].symbol == "cart")
    }

    @Test func unknownFolderIsReportedNotChanged() {
        var (folders, _, _, _, _) = makeBoard()
        let before = folders
        let missing = UUID()
        #expect(!LinkBoard.renameFolder(missing, to: "x", in: &folders))
        #expect(!LinkBoard.setColor("red", of: missing, in: &folders))
        #expect(!LinkBoard.deleteFolder(missing, in: &folders))
        #expect(folders == before)
    }

    @Test func deletingAFolderRemovesItsLinks() {
        var (folders, work, _, _, _) = makeBoard()
        #expect(LinkBoard.deleteFolder(work, in: &folders))
        #expect(folders.map(\.name) == ["Home"])
    }

    @Test func movesFoldersLikeOnMove() {
        var (folders, _, _, _, _) = makeBoard()
        folders.append(LinkFolder(name: "Third"))
        // Move "Work" (index 0) to the end: insertion point 3.
        #expect(LinkBoard.moveFolders(fromOffsets: IndexSet(integer: 0), toOffset: 3, in: &folders))
        #expect(folders.map(\.name) == ["Home", "Third", "Work"])
        #expect(!LinkBoard.moveFolders(fromOffsets: IndexSet(integer: 9), toOffset: 0, in: &folders))
    }

    @Test func addsLinksFromPastedText() throws {
        var (folders, work, _, _, _) = makeBoard()
        #expect(LinkBoard.addLink(from: "developer.apple.com", toFolder: work, in: &folders))
        let added = try #require(folders[0].links.last)
        #expect(added.url == "https://developer.apple.com")
        #expect(added.title == "developer.apple.com")

        #expect(!LinkBoard.addLink(from: "hello", toFolder: work, in: &folders))
        #expect(folders[0].links.count == 4)
    }

    @Test func updatesLinksAndFallsBackToHostForBlankTitle() throws {
        var (folders, work, a, _, _) = makeBoard()
        #expect(LinkBoard.updateLink(a, inFolder: work, title: "Alpha", urlText: "alpha.dev", in: &folders))
        #expect(folders[0].links[0].title == "Alpha")
        #expect(folders[0].links[0].url == "https://alpha.dev")

        #expect(LinkBoard.updateLink(a, inFolder: work, title: "  ", urlText: "https://www.alpha.dev/x", in: &folders))
        #expect(folders[0].links[0].title == "alpha.dev")

        #expect(!LinkBoard.updateLink(a, inFolder: work, title: "Bad", urlText: "nope", in: &folders))
        #expect(folders[0].links[0].url == "https://www.alpha.dev/x")
    }

    @Test func deletesAndReordersLinks() {
        var (folders, work, a, b, c) = makeBoard()
        #expect(LinkBoard.moveLinks(inFolder: work, fromOffsets: IndexSet(integer: 2), toOffset: 0, in: &folders))
        #expect(folders[0].links.map(\.id) == [c, a, b])

        // Move "c" (index 0 now) to insertion point 2: lands between "a" and "b".
        #expect(LinkBoard.moveLinks(inFolder: work, fromOffsets: IndexSet(integer: 0), toOffset: 2, in: &folders))
        #expect(folders[0].links.map(\.id) == [a, c, b])

        #expect(LinkBoard.deleteLink(a, inFolder: work, in: &folders))
        #expect(!LinkBoard.deleteLink(a, inFolder: work, in: &folders))
        #expect(folders[0].links.map(\.id) == [c, b])
    }

    @Test func movesSeveralLinksAsOneBlock() {
        let names = ["a", "b", "c", "d", "e"]
        let folder = LinkFolder(name: "Five", links: names.map { LinkItem(title: $0, url: "https://\($0).com") })
        var folders = [folder]
        func order() -> [String] { folders[0].links.map(\.title) }

        // Select "b" and "d", drop them before "e" (insertion point 4).
        #expect(LinkBoard.moveLinks(inFolder: folder.id, fromOffsets: IndexSet([1, 3]), toOffset: 4, in: &folders))
        #expect(order() == ["a", "c", "b", "d", "e"])
        // Drop "d" and "e" before "a".
        #expect(LinkBoard.moveLinks(inFolder: folder.id, fromOffsets: IndexSet([3, 4]), toOffset: 0, in: &folders))
        #expect(order() == ["d", "e", "a", "c", "b"])
        // Dropping onto the same spot changes nothing.
        #expect(LinkBoard.moveLinks(inFolder: folder.id, fromOffsets: IndexSet(integer: 2), toOffset: 2, in: &folders))
        #expect(order() == ["d", "e", "a", "c", "b"])
    }
}

@Suite("Links persistence")
struct LinksPersistenceTests {
    @Test func roundTripsFoldersAndLinks() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<LinksDocument>(url: temp.paths.linksFile)
        let link = LinkItem(title: "Swift", url: "https://swift.org", createdAt: referenceDate)
        let document = LinksDocument(folders: [LinkFolder(name: "Dev", colorName: "teal", symbol: "hammer", links: [link])])

        try store.save(document)
        let loaded = try #require(try store.load())
        #expect(loaded == document)
        #expect(loaded.schemaVersion == LinksDocument.currentSchemaVersion)
        #expect(loaded.folders[0].links[0].destination?.host == "swift.org")
    }
}
