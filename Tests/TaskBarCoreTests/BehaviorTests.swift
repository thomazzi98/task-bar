import Foundation
import Testing
@testable import TaskBarCore

@Suite("Popover behaviour")
struct PopoverBehaviorTests {
    /// A popover opened by resting the pointer on the icon.
    private func hovered() -> PopoverBehavior {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.hoverDelayElapsed(pointerOverIcon: true))
        return behavior
    }

    @Test func hoveringOpensWithoutTakingFocus() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.hoverDelayElapsed(pointerOverIcon: true)) == .show(takingFocus: false))
        #expect(behavior.isVisible)
        #expect(!behavior.isEngaged)
        #expect(behavior.needsPointerSampling)
    }

    @Test func hoverDoesNothingIfThePointerAlreadyLeft() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.hoverDelayElapsed(pointerOverIcon: false)) == nil)
        #expect(!behavior.isVisible)
    }

    @Test func hoverCanBeTurnedOff() {
        var behavior = PopoverBehavior(opensOnHover: false)
        #expect(behavior.handle(.hoverDelayElapsed(pointerOverIcon: true)) == nil)
        #expect(behavior.handle(.iconClicked) == .show(takingFocus: true))
    }

    @Test func aHoveredPopoverClosesAfterThePointerLeaves() {
        var behavior = hovered()
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: true)) == nil)
        // One miss is forgiven, so brushing past the edge does not close it.
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: true)) == nil)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == .hide)
        #expect(!behavior.isVisible)
    }

    @Test func interactingKeepsItOpenWhenThePointerLeaves() {
        var behavior = hovered()
        // Clicking inside makes the panel the key window.
        #expect(behavior.handle(.becameKey) == nil)
        #expect(behavior.isEngaged)
        #expect(!behavior.needsPointerSampling)
        for _ in 0..<5 {
            #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        }
        #expect(behavior.isVisible)
    }

    @Test func clickingTheIconRightAfterAHoverOpenKeepsItOpen() {
        var behavior = hovered()
        #expect(behavior.handle(.iconClicked) == .takeFocus)
        #expect(behavior.isVisible)
        #expect(behavior.isEngaged)
        // A second click is a real toggle.
        #expect(behavior.handle(.iconClicked) == .hide)
    }

    @Test func clickingTheIconTogglesAnEngagedPopover() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.iconClicked) == .show(takingFocus: true))
        #expect(behavior.isEngaged)
        #expect(behavior.handle(.iconClicked) == .hide)
        #expect(behavior.handle(.iconClicked) == .show(takingFocus: true))
    }

    @Test func theShortcutToggles() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.shortcutPressed) == .show(takingFocus: true))
        #expect(behavior.handle(.shortcutPressed) == .hide)
        // It also closes a popover that was merely hovered.
        behavior = hovered()
        #expect(behavior.handle(.shortcutPressed) == .hide)
    }

    @Test func anExplicitOpenRequestNeverCloses() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.openRequested) == .show(takingFocus: true))
        #expect(behavior.handle(.openRequested) == .takeFocus)
        #expect(behavior.isVisible)
    }

    @Test func clickingElsewhereClosesAnUnpinnedPopover() {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.iconClicked)
        #expect(behavior.handle(.clickedOutside) == .hide)
        #expect(behavior.handle(.clickedOutside) == nil)
    }

    @Test func losingFocusClosesUnlessTheClickWasOnTheIcon() {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.iconClicked)
        // The icon click handler decides in this case; closing here would reopen it at once.
        #expect(behavior.handle(.resignedKey(pointerOverIcon: true)) == nil)
        #expect(behavior.handle(.resignedKey(pointerOverIcon: false)) == .hide)
    }

    @Test func aPinnedPopoverStaysOpen() {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.iconClicked)
        behavior.isPinned = true
        #expect(behavior.handle(.clickedOutside) == nil)
        #expect(behavior.handle(.resignedKey(pointerOverIcon: false)) == nil)
        #expect(behavior.isVisible)

        // Even a hovered one, once pinned, ignores the pointer leaving.
        var hoveredAndPinned = hovered()
        hoveredAndPinned.isPinned = true
        for _ in 0..<4 {
            #expect(hoveredAndPinned.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        }
        #expect(hoveredAndPinned.isVisible)
    }

    @Test func theUserCanAlwaysDismissAPinnedPopover() {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.iconClicked)
        behavior.isPinned = true
        #expect(behavior.handle(.dismissRequested) == .hide)
        #expect(behavior.handle(.dismissRequested) == nil)

        _ = behavior.handle(.iconClicked)
        #expect(behavior.handle(.iconClicked) == .hide)
    }

    @Test func aSystemPromptHoldsThePopoverOpen() {
        var behavior = PopoverBehavior()
        _ = behavior.handle(.iconClicked)
        behavior.isHeldOpen = true
        #expect(behavior.handle(.resignedKey(pointerOverIcon: false)) == nil)
        #expect(behavior.handle(.clickedOutside) == nil)
        behavior.isHeldOpen = false
        #expect(behavior.handle(.clickedOutside) == .hide)
    }

    @Test func eventsForAHiddenPopoverAreIgnored() {
        var behavior = PopoverBehavior()
        #expect(behavior.handle(.becameKey) == nil)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        #expect(behavior.handle(.resignedKey(pointerOverIcon: false)) == nil)
        #expect(!behavior.isEngaged)
        #expect(!behavior.isVisible)
    }

    @Test func reopeningStartsFresh() {
        var behavior = hovered()
        _ = behavior.handle(.pointerSampled(isInsideHoverRegion: false))
        _ = behavior.handle(.becameKey)
        _ = behavior.handle(.clickedOutside)

        // The earlier miss and engagement must not leak into the next hover.
        #expect(behavior.handle(.hoverDelayElapsed(pointerOverIcon: true)) == .show(takingFocus: false))
        #expect(!behavior.isEngaged)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == nil)
        #expect(behavior.handle(.pointerSampled(isInsideHoverRegion: false)) == .hide)
    }
}

@Suite("URL commands")
struct URLCommandTests {
    private func command(_ string: String) -> URLCommand? {
        URL(string: string).flatMap(URLCommand.init(url:))
    }

    @Test func parsesVisibilityCommands() {
        #expect(command("taskbar://open") == .open)
        #expect(command("taskbar://show") == .open)
        #expect(command("taskbar://toggle") == .toggle)
        #expect(command("taskbar://close") == .close)
        #expect(command("TASKBAR://Toggle") == .toggle)
    }

    @Test func parsesTabs() {
        #expect(command("taskbar://tab/agents") == .showTab("agents"))
        #expect(command("taskbar://tab/System") == .showTab("system"))
        #expect(command("taskbar://tab") == nil)
    }

    @Test func parsesNewItems() {
        #expect(command("taskbar://new-task?title=Call%20the%20bank") == .addTask(title: "Call the bank"))
        #expect(command("taskbar://new-note?text=Remember%20the%20milk") == .addNote(text: "Remember the milk", isPrompt: false))
        #expect(command("taskbar://new-note?text=Build%20a%20CLI&kind=prompt") == .addNote(text: "Build a CLI", isPrompt: true))
        #expect(command("taskbar://new-prompt?text=Build%20a%20CLI") == .addNote(text: "Build a CLI", isPrompt: true))
    }

    @Test func namesCommandsWithoutLeakingTheirText() {
        #expect(command("taskbar://new-task?title=Secret%20plan")?.name == "new-task")
        #expect(command("taskbar://new-prompt?text=Secret")?.name == "new-prompt")
        #expect(command("taskbar://new-note?text=Secret")?.name == "new-note")
        #expect(command("taskbar://tab/agents")?.name == "tab")
    }

    @Test func rejectsIncompleteOrUnknownCommands() {
        #expect(command("taskbar://new-task") == nil)
        #expect(command("taskbar://new-task?title=%20%20") == nil)
        #expect(command("taskbar://new-note?title=wrong-parameter") == nil)
        #expect(command("taskbar://delete-everything") == nil)
        #expect(command("https://example.com/open") == nil)
    }

    @Test func capsOversizedText() {
        let huge = String(repeating: "a", count: URLCommand.maximumTextLength + 500)
        guard case .addNote(let text, _) = command("taskbar://new-note?text=\(huge)") else {
            Issue.record("expected a note command")
            return
        }
        #expect(text.count == URLCommand.maximumTextLength)
    }
}
