import AppKit
import SwiftUI
import TaskBarCore

/// Preferences, shown inside the popover so no extra window is needed.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AgentsViewModel.self) private var agents
    @Environment(AgendaViewModel.self) private var agenda
    @Environment(AppState.self) private var appState
    @Environment(\.appActions) private var actions

    @State private var launchesAtLogin = LoginItemManager.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            BackBar(title: "Settings", onBack: { appState.isShowingSettings = false }) {
                Text("TaskBar \(AppBundle.version)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsSection("General") {
                        ToggleRow("Launch at login", isOn: Binding(
                            get: { launchesAtLogin },
                            set: { enabled in
                                loginItemError = LoginItemManager.setEnabled(enabled)
                                launchesAtLogin = LoginItemManager.isEnabled
                            }
                        ))
                        .disabled(!LoginItemManager.isSupported)
                        if let loginItemError {
                            Text(loginItemError).settingsCaption()
                        }
                        ToggleRow("Open when hovering the menu bar icon", isOn: $settings.opensOnHover)
                        ShortcutRow(title: "Show or hide TaskBar", combo: $settings.toggleShortcut)
                        ShortcutRow(title: "New note by voice", combo: $settings.voiceShortcut)
                    }

                    SettingsSection("Tabs") {
                        ForEach(AppTab.allCases) { tab in
                            ToggleRow(tab.title, symbol: tab.symbol, isOn: Binding(
                                get: { settings.isEnabled(tab) },
                                set: { settings.setEnabled($0, for: tab) }
                            ))
                        }
                        Text("Hide the sections you do not use to keep TaskBar minimal.").settingsCaption()
                    }

                    SettingsSection("Claude Code") {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Instant alerts (hooks)").font(.system(size: 12.5))
                                Text(agents.hooksInstalled ? "Installed in ~/.claude/settings.json" : "Not installed")
                                    .font(.system(size: 11))
                                    .foregroundStyle(agents.hooksInstalled ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                            }
                            Spacer()
                            if agents.hooksInstalled {
                                PillButton(title: "Remove", tint: .secondary) { agents.uninstallHooks() }
                            } else {
                                PillButton(title: "Install", isProminent: true) { agents.installHooks() }
                            }
                        }
                        if let message = agents.hookMessage {
                            Text(message).settingsCaption()
                        }
                        ToggleRow("Notify me when an agent needs me", isOn: $settings.notifiesOnAttention)
                            .onChange(of: settings.notifiesOnAttention) { _, enabled in
                                if enabled { actions.requestNotificationPermission() }
                            }
                        Text("Hooks tell TaskBar the moment an agent asks for permission. Your existing hooks are kept and a backup of the settings file is made.")
                            .settingsCaption()
                    }

                    SettingsSection("Voice and Tidy up") {
                        PickerRow("Dictation language", selection: $settings.dictationLocaleIdentifier) {
                            Text("System language").tag("")
                            ForEach(Dictation.commonLocaleIdentifiers, id: \.self) { identifier in
                                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
                            }
                        }
                        PickerRow("Tidy up model", selection: $settings.polisherPreference) {
                            ForEach(PolisherPreference.allCases) { preference in
                                Text(preference.label).tag(preference)
                            }
                        }
                        ForEach(PolisherProvider.statusLines(), id: \.name) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: line.isAvailable ? "checkmark.circle.fill" : "minus.circle")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(line.isAvailable ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                                    .padding(.top, 1.5)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(line.name).font(.system(size: 11.5, weight: .medium))
                                    Text(line.detail).settingsCaption()
                                }
                            }
                        }
                        Text("Dictation runs entirely on this Mac. Tidy up is optional: TaskBar works fully without any model.")
                            .settingsCaption()
                    }

                    SettingsSection("Calendar") {
                        PickerRow("Remind me before events", selection: $settings.calendarReminderMinutes) {
                            Text("Off").tag(0)
                            Text("5 minutes").tag(5)
                            Text("10 minutes").tag(10)
                            Text("15 minutes").tag(15)
                        }
                        .onChange(of: settings.calendarReminderMinutes) { agenda.rescheduleReminders() }
                    }

                    SettingsSection("System") {
                        ToggleRow("Show stopped Docker containers", isOn: $settings.showsStoppedContainers)
                    }

                    SettingsSection("Data") {
                        HStack(spacing: 8) {
                            PillButton(title: "Show data folder", symbol: "folder", tint: .secondary) { actions.revealDataFolder() }
                            PillButton(title: "GitHub", symbol: "arrow.up.right", tint: .secondary) {
                                if let url = URL(string: "https://github.com/thomazzi98/task-bar") { Opener.open(url) }
                            }
                            Spacer()
                            PillButton(title: "Quit TaskBar", symbol: "power", tint: .red) { actions.quit() }
                        }
                        Text("Tasks and notes are plain JSON files you can read, back up or sync yourself.").settingsCaption()
                    }
                }
                .padding(.horizontal, Design.gutter)
                .padding(.top, 4)
                .padding(.bottom, 14)
            }
        }
    }
}

// MARK: - Building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var symbol: String?
    @Binding var isOn: Bool

    init(_ title: String, symbol: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.symbol = symbol
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                }
                Text(title).font(.system(size: 12.5))
                Spacer()
            }
        }
        .toggleStyle(SwitchToggleStyle())
    }
}

private struct PickerRow<Selection: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        _selection = selection
        self.options = options()
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
        }
    }
}

private extension Text {
    func settingsCaption() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Shows a global shortcut and records a new one from the next key press.
private struct ShortcutRow: View {
    let title: String
    @Binding var combo: KeyCombo?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12.5))
            Spacer()
            Button(action: toggleRecording) {
                Text(isRecording ? "Press keys…" : combo?.display ?? "None")
                    .font(.system(size: 11.5, weight: .medium, design: isRecording ? .default : .rounded))
                    .foregroundStyle(isRecording ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .frame(minWidth: 62)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(isRecording ? 0.10 : 0.07))
                    )
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut. Delete clears it; Escape cancels.")
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        // A local monitor sees the key press before the panel does, so Escape cancels the
        // recording instead of closing the popover.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            break
        case 51, 117: // Delete, Forward Delete
            combo = nil
        default:
            guard let recorded = KeyCombo(event: event) else { return }
            combo = recorded
        }
        stopRecording()
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
