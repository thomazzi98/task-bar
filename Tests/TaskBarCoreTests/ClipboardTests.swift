import Foundation
import Testing
@testable import TaskBarCore

@Suite("Clipboard history")
struct ClipboardTests {
    private let start = referenceDate

    @Test func newestCopyComesFirst() {
        var history = ClipboardHistory()
        history.insert("first", at: start)
        history.insert("second", at: start.addingTimeInterval(1))
        #expect(history.items.map(\.text) == ["second", "first"])
    }

    @Test func identicalTextMovesToTheTopInsteadOfDuplicating() throws {
        var history = ClipboardHistory()
        let firstIDResult = history.insert("a", at: start)
        let firstID = try #require(firstIDResult)
        history.insert("b", at: start.addingTimeInterval(1))
        let secondIDResult = history.insert("a", at: start.addingTimeInterval(2))
        let secondID = try #require(secondIDResult)

        #expect(history.items.map(\.text) == ["a", "b"])
        #expect(firstID == secondID)
        #expect(history.items[0].copiedAt == start.addingTimeInterval(2))
    }

    @Test func skipsEmptyWhitespaceAndOversizedText() {
        var history = ClipboardHistory()
        #expect(history.insert("") == nil)
        #expect(history.insert(" \n\t ") == nil)
        #expect(history.insert(String(repeating: "x", count: ClipboardPolicy.maxTextBytes + 1)) == nil)
        #expect(history.items.isEmpty)

        #expect(history.insert(String(repeating: "x", count: ClipboardPolicy.maxTextBytes)) != nil)
    }

    @Test func keepsTextExactlyAsCopied() {
        var history = ClipboardHistory()
        history.insert("  padded text\n", at: start)
        #expect(history.items.first?.text == "  padded text\n")
    }

    @Test func evictsTheOldestUnpinnedItemsBeyondTheLimit() {
        var history = ClipboardHistory()
        let total = ClipboardHistory.unpinnedLimit + 5
        for index in 0..<total {
            history.insert("item \(index)", at: start.addingTimeInterval(Double(index)))
        }
        #expect(history.items.count == ClipboardHistory.unpinnedLimit)
        #expect(history.items.first?.text == "item \(total - 1)")
        #expect(history.items.last?.text == "item 5")
    }

    /// A copy just under the per-copy size cap, labelled so tests can tell copies apart.
    private func largeCopy(_ label: String) -> String {
        label + "|" + String(repeating: "x", count: 90 * 1_024)
    }

    /// The labels of the stored copies, newest first.
    private func labels(_ history: ClipboardHistory) -> [String] {
        history.items.map { String($0.text.prefix { $0 != "|" }) }
    }

    @Test func evictsOldestUnpinnedCopiesOnceTheTextBudgetIsExceeded() {
        var history = ClipboardHistory()
        // Twelve 90 KB copies are about 1.1 MB. The oldest goes, leaving eleven (about 1.0 MB).
        for index in 0..<12 {
            history.insert(largeCopy("copy \(index)"), at: start.addingTimeInterval(Double(index)))
        }
        let storedBytes = history.items.reduce(0) { $0 + $1.text.utf8.count }
        #expect(history.items.count == 11)
        #expect(labels(history).first == "copy 11")
        #expect(labels(history).last == "copy 1")
        #expect(storedBytes <= ClipboardHistory.byteLimit)
    }

    @Test func pinnedCopiesCountTowardsTheBudgetButAreNeverEvicted() throws {
        var history = ClipboardHistory()
        let pinnedResult = history.insert(largeCopy("pinned"), at: start)
        let pinnedID = try #require(pinnedResult)
        history.togglePin(pinnedID)
        for index in 0..<12 {
            history.insert(largeCopy("copy \(index)"), at: start.addingTimeInterval(Double(index + 1)))
        }
        // The pinned copy takes room in the budget, so ten unpinned copies fit beside it.
        #expect(history.items.count == 11)
        #expect(labels(history).last == "pinned")
        #expect(labels(history).first == "copy 11")
        #expect(history.items.contains { $0.id == pinnedID })
    }

    @Test func pinnedItemsAreNeverEvicted() throws {
        var history = ClipboardHistory()
        let pinnedIDResult = history.insert("keep me", at: start)
        let pinnedID = try #require(pinnedIDResult)
        history.togglePin(pinnedID)

        for index in 0..<(ClipboardHistory.unpinnedLimit + 10) {
            history.insert("later \(index)", at: start.addingTimeInterval(Double(index + 1)))
        }

        #expect(history.items.contains { $0.id == pinnedID && $0.isPinned })
        #expect(history.unpinnedCount == ClipboardHistory.unpinnedLimit)
        #expect(history.items.count == ClipboardHistory.unpinnedLimit + 1)
    }

    @Test func unpinningOverTheLimitEvictsTheOldest() throws {
        var history = ClipboardHistory()
        let pinnedIDResult = history.insert("pinned", at: start)
        let pinnedID = try #require(pinnedIDResult)
        history.togglePin(pinnedID)
        for index in 0..<ClipboardHistory.unpinnedLimit {
            history.insert("item \(index)", at: start.addingTimeInterval(Double(index + 1)))
        }
        #expect(history.items.count == ClipboardHistory.unpinnedLimit + 1)

        history.togglePin(pinnedID)
        // The unpinned item is the oldest one overall, so it is the one that goes.
        #expect(history.unpinnedCount == ClipboardHistory.unpinnedLimit)
        #expect(!history.items.contains { $0.id == pinnedID })
    }

    @Test func togglePinTwiceRestoresTheItem() throws {
        var history = ClipboardHistory()
        let idResult = history.insert("x", at: start)
        let id = try #require(idResult)
        history.togglePin(id)
        #expect(history.items.first?.isPinned == true)
        history.togglePin(id)
        #expect(history.items.first?.isPinned == false)
    }

    @Test func removeDeletesOnlyThatItem() throws {
        var history = ClipboardHistory()
        history.insert("a", at: start)
        let idResult = history.insert("b", at: start.addingTimeInterval(1))
        let id = try #require(idResult)
        history.remove(id)
        #expect(history.items.map(\.text) == ["a"])
    }

    @Test func clearUnpinnedKeepsPinnedItems() throws {
        var history = ClipboardHistory()
        let pinnedIDResult = history.insert("pinned", at: start)
        let pinnedID = try #require(pinnedIDResult)
        history.togglePin(pinnedID)
        history.insert("plain", at: start.addingTimeInterval(1))

        history.clearUnpinned()
        #expect(history.items.map(\.text) == ["pinned"])
    }

    @Test func clearAllRemovesEverything() throws {
        var history = ClipboardHistory()
        let pinnedIDResult = history.insert("pinned", at: start)
        let pinnedID = try #require(pinnedIDResult)
        history.togglePin(pinnedID)
        history.insert("plain", at: start.addingTimeInterval(1))

        history.clearAll()
        #expect(history.items.isEmpty)
    }

    @Test func orderedListsPinnedItemsFirst() throws {
        var history = ClipboardHistory()
        let oldPinnedResult = history.insert("old pinned", at: start)
        let oldPinned = try #require(oldPinnedResult)
        history.togglePin(oldPinned)
        history.insert("recent", at: start.addingTimeInterval(10))

        #expect(history.ordered.map(\.text) == ["old pinned", "recent"])
    }

    @Test func searchIgnoresCaseAndDiacritics() {
        var history = ClipboardHistory()
        history.insert("Café com leite", at: start)
        history.insert("https://Example.com/Path", at: start.addingTimeInterval(1))

        #expect(history.search("cafe").map(\.text) == ["Café com leite"])
        #expect(history.search("CAFÉ").map(\.text) == ["Café com leite"])
    }

    @Test func searchRequiresEveryWord() {
        var history = ClipboardHistory()
        history.insert("https://Example.com/Path", at: start)
        history.insert("unrelated text", at: start.addingTimeInterval(1))

        #expect(history.search("EXAMPLE path").map(\.text) == ["https://Example.com/Path"])
        #expect(history.search("example missing").isEmpty)
    }

    @Test func emptyQueryReturnsEverythingInOrder() throws {
        var history = ClipboardHistory()
        let pinnedIDResult = history.insert("pinned", at: start)
        let pinnedID = try #require(pinnedIDResult)
        history.togglePin(pinnedID)
        history.insert("recent", at: start.addingTimeInterval(1))

        #expect(history.search("   ").map(\.text) == ["pinned", "recent"])
    }

    @Test func loadingSortsByRecencyAndAppliesTheLimit() {
        let items = [
            ClipboardItem(text: "old", copiedAt: start),
            ClipboardItem(text: "new", copiedAt: start.addingTimeInterval(5))
        ]
        let history = ClipboardHistory(items: items)
        #expect(history.items.map(\.text) == ["new", "old"])
    }

    @Test func concealedPasteboardTypesAreRecognised() {
        #expect(ClipboardPolicy.isConcealed(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(ClipboardPolicy.isConcealed(types: ["com.agilebits.onepassword"]))
        #expect(!ClipboardPolicy.isConcealed(types: ["public.utf8-plain-text", "public.html"]))
    }

    @Test func recognisesCodeLikeText() {
        func item(_ text: String) -> ClipboardItem { ClipboardItem(text: text) }
        #expect(item("https://example.com/a").looksLikeCode)
        #expect(item("/Users/me/project/file.txt").looksLikeCode)
        #expect(item("func run() { return 1; }").looksLikeCode)
        #expect(item("if x {\n    y()\n}").looksLikeCode)
        #expect(!item("Buy milk on the way home").looksLikeCode)
    }

    @Test func formatsRelativeAges() {
        let item = ClipboardItem(text: "x", copiedAt: start)
        #expect(item.age(now: start.addingTimeInterval(30)) == "just now")
        #expect(item.age(now: start.addingTimeInterval(150)) == "2m ago")
        #expect(item.age(now: start.addingTimeInterval(7_200)) == "2h ago")
        #expect(item.age(now: start.addingTimeInterval(3 * 86_400)) == "3d ago")
    }

    @Test func documentRoundTripsThroughTheStore() throws {
        let temp = try TemporaryDirectory()
        defer { temp.remove() }
        let store = JSONFileStore<ClipboardDocument>(url: temp.paths.clipboardFile)
        let document = ClipboardDocument(items: [ClipboardItem(text: "saved", copiedAt: start, isPinned: true)])

        try store.save(document)
        #expect(try store.load() == document)
        #expect(try store.load()?.schemaVersion == ClipboardDocument.currentSchemaVersion)
    }
}
