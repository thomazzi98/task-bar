import Foundation

/// The rules for when the menu bar popover opens and closes, as a pure state machine.
///
/// Keeping the rules free of AppKit makes them unit-testable; the status item controller
/// only translates real events into `Event` values and carries out the returned `Effect`.
///
/// The behaviour in short:
/// - Resting the pointer on the icon opens the popover without taking keyboard focus.
/// - A popover that was only hovered closes soon after the pointer leaves.
/// - Any interaction (a click inside, opening by click or shortcut) *engages* it: it then
///   stays until dismissed, a click lands elsewhere, or focus moves to another window.
/// - Pinned, or while a system prompt is up, it never closes on its own.
public struct PopoverBehavior: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// The pointer rested on the icon for the hover delay.
        case hoverDelayElapsed(pointerOverIcon: Bool)
        case iconClicked
        case shortcutPressed
        /// An explicit request to show the popover (context menu, URL command).
        case openRequested
        /// A periodic check of the pointer while the popover is merely hovered.
        case pointerSampled(isInsideHoverRegion: Bool)
        case becameKey
        case resignedKey(pointerOverIcon: Bool)
        case clickedOutside
        /// The user dismissed the popover (Escape at the top level, ⌘W).
        case dismissRequested
    }

    public enum Effect: Equatable, Sendable {
        /// Show the popover; `takingFocus` makes it the key window and focuses its main field.
        case show(takingFocus: Bool)
        /// The popover is already visible: give it keyboard focus.
        case takeFocus
        case hide
    }

    /// Consecutive pointer samples outside the hover region before a hovered popover closes.
    /// Two samples forgive briefly overshooting the edge.
    public static let missedSamplesBeforeClosing = 2

    public private(set) var isVisible = false
    /// The user has interacted with the popover, so the pointer leaving must not close it.
    public private(set) var isEngaged = false
    public var isPinned = false
    /// A system prompt (for example a permission dialog) is in front; never close meanwhile.
    public var isHeldOpen = false
    public var opensOnHover = true

    private var missedSamples = 0

    public init(opensOnHover: Bool = true) {
        self.opensOnHover = opensOnHover
    }

    /// Whether the pointer needs to be sampled: only while a popover is open but untouched.
    public var needsPointerSampling: Bool {
        isVisible && !isEngaged
    }

    private var staysOpen: Bool {
        isPinned || isHeldOpen
    }

    /// Advances the state and returns what the controller must do, if anything.
    public mutating func handle(_ event: Event) -> Effect? {
        switch event {
        case .hoverDelayElapsed(let pointerOverIcon):
            guard opensOnHover, pointerOverIcon, !isVisible else { return nil }
            isVisible = true
            isEngaged = false
            missedSamples = 0
            return .show(takingFocus: false)

        case .iconClicked:
            if !isVisible { return open() }
            // A click right after a hover-open means "open", not "close": keep it and engage.
            if !isEngaged { return engage() }
            return close()

        case .shortcutPressed:
            return isVisible ? close() : open()

        case .openRequested:
            return isVisible ? engage() : open()

        case .pointerSampled(let isInsideHoverRegion):
            guard needsPointerSampling, !staysOpen else { return nil }
            missedSamples = isInsideHoverRegion ? 0 : missedSamples + 1
            return missedSamples >= Self.missedSamplesBeforeClosing ? close() : nil

        case .becameKey:
            guard isVisible else { return nil }
            isEngaged = true
            return nil

        case .resignedKey(let pointerOverIcon):
            // A click on our own icon also takes focus away; the click itself decides then.
            guard isVisible, !staysOpen, !pointerOverIcon else { return nil }
            return close()

        case .clickedOutside:
            guard isVisible, !staysOpen else { return nil }
            return close()

        case .dismissRequested:
            return isVisible ? close() : nil
        }
    }

    private mutating func open() -> Effect {
        isVisible = true
        isEngaged = true
        missedSamples = 0
        return .show(takingFocus: true)
    }

    private mutating func engage() -> Effect {
        isEngaged = true
        return .takeFocus
    }

    private mutating func close() -> Effect {
        isVisible = false
        isEngaged = false
        missedSamples = 0
        return .hide
    }
}
