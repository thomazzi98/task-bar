import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts.
///
/// Uses the Carbon hot-key API, which needs no Accessibility permission, unlike event taps.
@MainActor
final class HotKeyManager {
    /// Identifies a shortcut slot.
    enum Slot: UInt32 {
        case togglePanel = 1
        case voiceCapture = 2
    }

    private static let signature: OSType = 0x5442_4152 // "TBAR"

    private var handlers: [UInt32: () -> Void] = [:]
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    /// Binds `combo` to `slot`, replacing any previous binding. Passing `nil` clears it.
    /// Returns `false` when the system refuses the shortcut (usually because it is taken).
    @discardableResult
    func bind(_ slot: Slot, to combo: KeyCombo?, handler: @escaping () -> Void) -> Bool {
        unbind(slot)
        guard let combo else { return true }
        installEventHandlerIfNeeded()

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: slot.rawValue)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            identifier,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        registrations[slot.rawValue] = reference
        handlers[slot.rawValue] = handler
        return true
    }

    func unbind(_ slot: Slot) {
        if let reference = registrations.removeValue(forKey: slot.rawValue) {
            UnregisterEventHotKey(reference)
        }
        handlers[slot.rawValue] = nil
    }

    fileprivate func fire(_ identifier: UInt32) {
        handlers[identifier]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}

/// Carbon delivers hot-key events on the main thread's event loop.
private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    let slot = identifier.id
    MainActor.assumeIsolated {
        manager.fire(slot)
    }
    return noErr
}

extension KeyCombo {
    /// Builds a combo from a key-down event, or `nil` when it has no usable modifier.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        // Shift alone would shadow ordinary typing, so require a real modifier.
        guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        guard let label = Self.label(for: event) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }

    private static func label(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1...kVK_F20 where functionKeyNames[Int(event.keyCode)] != nil:
            return functionKeyNames[Int(event.keyCode)]
        default:
            break
        }
        guard let characters = event.charactersIgnoringModifiers?.uppercased(),
              let first = characters.first, first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol
        else { return nil }
        return String(first)
    }

    private static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]
}
