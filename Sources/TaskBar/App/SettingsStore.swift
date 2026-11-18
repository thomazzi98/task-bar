import Carbon.HIToolbox
import Foundation
import Observation

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key's printable name, captured when the shortcut was recorded.
    var keyLabel: String

    static let defaultToggle = KeyCombo(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "T"
    )

    static let defaultVoiceCapture = KeyCombo(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "V"
    )

    /// Human-readable form such as `⌃⌥T`.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }
}

/// Which model rewrites text for "Tidy up".
enum PolisherPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic, appleIntelligence, claude

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .appleIntelligence: "Apple Intelligence (on-device)"
        case .claude: "Claude via Claude Code"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let opensOnHover = "opensOnHover"
        static let disabledTabs = "disabledTabs"
        static let toggleShortcut = "toggleShortcut"
        static let voiceShortcut = "voiceShortcut"
        static let notifiesOnAttention = "notifiesOnAttention"
        static let calendarReminderMinutes = "calendarReminderMinutes"
        static let dictationLocale = "dictationLocale"
        static let polisherPreference = "polisherPreference"
        static let showsStoppedContainers = "showsStoppedContainers"
        static let lastTab = "lastTab"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var opensOnHover: Bool {
        didSet { defaults.set(opensOnHover, forKey: Key.opensOnHover) }
    }

    /// Raw values of the tabs the user hid.
    var disabledTabs: Set<String> {
        didSet { defaults.set(Array(disabledTabs).sorted(), forKey: Key.disabledTabs) }
    }

    /// `nil` means the shortcut was cleared.
    var toggleShortcut: KeyCombo? {
        didSet { store(toggleShortcut, forKey: Key.toggleShortcut) }
    }

    var voiceShortcut: KeyCombo? {
        didSet { store(voiceShortcut, forKey: Key.voiceShortcut) }
    }

    var notifiesOnAttention: Bool {
        didSet { defaults.set(notifiesOnAttention, forKey: Key.notifiesOnAttention) }
    }

    /// Minutes before an event to send a reminder. `0` turns reminders off.
    var calendarReminderMinutes: Int {
        didSet { defaults.set(calendarReminderMinutes, forKey: Key.calendarReminderMinutes) }
    }

    /// BCP 47 identifier of the dictation language. Empty follows the system language.
    var dictationLocaleIdentifier: String {
        didSet { defaults.set(dictationLocaleIdentifier, forKey: Key.dictationLocale) }
    }

    var polisherPreference: PolisherPreference {
        didSet { defaults.set(polisherPreference.rawValue, forKey: Key.polisherPreference) }
    }

    var showsStoppedContainers: Bool {
        didSet { defaults.set(showsStoppedContainers, forKey: Key.showsStoppedContainers) }
    }

    var lastTab: AppTab {
        didSet { defaults.set(lastTab.rawValue, forKey: Key.lastTab) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        opensOnHover = defaults.object(forKey: Key.opensOnHover) as? Bool ?? true
        disabledTabs = Set(defaults.stringArray(forKey: Key.disabledTabs) ?? [])
        toggleShortcut = Self.loadCombo(from: defaults, key: Key.toggleShortcut, fallback: .defaultToggle)
        voiceShortcut = Self.loadCombo(from: defaults, key: Key.voiceShortcut, fallback: .defaultVoiceCapture)
        notifiesOnAttention = defaults.bool(forKey: Key.notifiesOnAttention)
        calendarReminderMinutes = defaults.integer(forKey: Key.calendarReminderMinutes)
        dictationLocaleIdentifier = defaults.string(forKey: Key.dictationLocale) ?? ""
        polisherPreference = defaults.string(forKey: Key.polisherPreference)
            .flatMap(PolisherPreference.init(rawValue:)) ?? .automatic
        showsStoppedContainers = defaults.bool(forKey: Key.showsStoppedContainers)
        lastTab = defaults.string(forKey: Key.lastTab).flatMap(AppTab.init(rawValue:)) ?? .tasks
    }

    // MARK: Tabs

    func isEnabled(_ tab: AppTab) -> Bool {
        !disabledTabs.contains(tab.rawValue)
    }

    func setEnabled(_ isEnabled: Bool, for tab: AppTab) {
        if isEnabled {
            disabledTabs.remove(tab.rawValue)
        } else if enabledTabs.count > 1 {
            // At least one tab must remain, or the popover would be empty.
            disabledTabs.insert(tab.rawValue)
        }
    }

    var enabledTabs: [AppTab] {
        AppTab.allCases.filter(isEnabled)
    }

    /// The tab to show for a selection: the selection itself, or the first enabled tab when
    /// the selected one has been hidden.
    func visibleTab(for selection: AppTab) -> AppTab {
        isEnabled(selection) ? selection : enabledTabs.first ?? .tasks
    }

    /// The locale used for dictation.
    var dictationLocale: Locale {
        dictationLocaleIdentifier.isEmpty ? .current : Locale(identifier: dictationLocaleIdentifier)
    }

    // MARK: Shortcut persistence

    /// A cleared shortcut is stored as empty data, to tell it apart from "never configured".
    private func store(_ combo: KeyCombo?, forKey key: String) {
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: key)
    }

    private static func loadCombo(from defaults: UserDefaults, key: String, fallback: KeyCombo) -> KeyCombo? {
        guard let data = defaults.data(forKey: key) else { return fallback }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}
