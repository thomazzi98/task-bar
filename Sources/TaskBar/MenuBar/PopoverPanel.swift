import AppKit
import SwiftUI

/// The window that drops down from the menu bar icon.
///
/// It is a non-activating panel: it can show on hover and accept typing without making
/// TaskBar the active app, so whatever the user was working in keeps its focus state.
final class PopoverPanel: NSPanel {
    /// Called for the Escape key. Return `true` when the key was consumed.
    var onEscape: (() -> Bool)?
    /// Called for ⌘-shortcuts that are not standard editing commands. Return `true` when handled.
    var onCommandKey: ((String) -> Bool)?

    private static let escapeKeyCode: UInt16 = 53
    static let cornerRadius: CGFloat = 12

    init(contentSize: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Hosts a SwiftUI view on top of the standard popover material.
    func setContent(_ view: some View) {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: view)
        // The panel dictates the size; the SwiftUI content must not resize the window.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        contentView = effect
    }

    // MARK: Keyboard

    override func sendEvent(_ event: NSEvent) {
        // Escape is intercepted here because text views otherwise swallow it for completion.
        // While an input method is composing, Escape belongs to it.
        if event.type == .keyDown, event.keyCode == Self.escapeKeyCode, !isComposingText,
           onEscape?() == true {
            return
        }
        super.sendEvent(event)
    }

    /// An accessory app has no menu bar, so the standard editing shortcuts that normally come
    /// from the Edit menu are routed by hand.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        let isShifted = flags.contains(.shift)
        switch (key, isShifted) {
        case ("x", false): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case ("c", false): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case ("v", false): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case ("a", false): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case ("z", _):
            guard let undoManager = firstResponder?.undoManager else { return false }
            if isShifted {
                if undoManager.canRedo { undoManager.redo() }
            } else if undoManager.canUndo {
                undoManager.undo()
            }
            return true
        default:
            return !isShifted && onCommandKey?(key) == true
        }
    }

    private var isComposingText: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}
