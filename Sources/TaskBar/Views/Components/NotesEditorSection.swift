import SwiftUI
import TaskBarCore

/// The notes editor shared by tasks and free-standing notes: a Markdown editor with a preview
/// mode, voice dictation, and a model-backed "Tidy up" that proposes a rewrite to accept or
/// discard.
struct NotesEditorSection: View {
    /// Identifies this editor to the shared `TextAssistant`.
    let targetID: String
    @Binding var text: String
    /// How "Tidy up" rewrites by default; the other style stays one click away in the menu.
    var style: PolishStyle = .note
    var placeholder = "Write here…"
    /// When `true`, the editor takes focus whenever the popover asks for its primary field.
    var isPrimary = false

    @Environment(TextAssistant.self) private var assistant
    @Environment(AppState.self) private var appState
    @Environment(SettingsStore.self) private var settings
    /// Remembers whether the user prefers to open notes rendered or as raw text.
    @AppStorage("editor.opensInPreview") private var opensInPreview = false
    @State private var isPreviewing = false
    @State private var proxy = EditorProxy()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .bottom) {
                content
                statusOverlay
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04))
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onAppear {
            // An empty note always opens ready for typing.
            isPreviewing = opensInPreview && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        .onChange(of: appState.focusRequest) {
            if isPrimary, !isPreviewing { proxy.focusAtEnd() }
        }
        .onDisappear { assistant.forget(targetID: targetID) }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            dictationButton
            dictationLanguageMenu
            polishMenu
            if assistant.canRevert(targetID) {
                IconButton(symbol: "arrow.uturn.backward", help: "Restore the text from before the rewrite") {
                    assistant.revert(targetID: targetID) { text = $0 }
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: "doc.on.doc", help: "Copy text") {
                Opener.copyToPasteboard(text)
                appState.showToast("Copied to clipboard")
            }
            .disabled(text.isEmpty)
            IconButton(
                symbol: isPreviewing ? "pencil" : "eye",
                help: isPreviewing ? "Edit" : "Preview Markdown",
                isActive: isPreviewing
            ) {
                isPreviewing.toggle()
                opensInPreview = isPreviewing
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private var dictationButton: some View {
        let isActive = assistant.isDictating(targetID)
        return IconButton(
            symbol: isActive ? "mic.fill" : "mic",
            help: isActive ? "Stop dictation" : "Dictate (on-device)",
            isActive: isActive,
            tint: .red
        ) {
            isPreviewing = false
            assistant.toggleDictation(
                targetID: targetID,
                text: text,
                insertionOffset: proxy.insertionOffset
            ) { text = $0 }
        }
    }

    /// Shows the dictation language as a short code and switches it in one click.
    private var dictationLanguageMenu: some View {
        Menu {
            ForEach(Dictation.commonLocaleIdentifiers, id: \.self) { identifier in
                languageItem("\(Dictation.label(for: identifier)) (\(identifier))", identifier: identifier)
            }
            Divider()
            languageItem("System language", identifier: "")
        } label: {
            Text(dictationLanguageCode)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .plainMenu()
        .help("Dictation language")
    }

    private var dictationLanguageCode: String {
        settings.dictationLocale.language.languageCode?.identifier.uppercased() ?? "--"
    }

    private func languageItem(_ title: String, identifier: String) -> some View {
        Button {
            selectDictationLanguage(identifier)
        } label: {
            if settings.dictationLocaleIdentifier == identifier {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// The language is read when dictation starts, so a running session is stopped and the next
    /// one uses the new language.
    private func selectDictationLanguage(_ identifier: String) {
        guard settings.dictationLocaleIdentifier != identifier else { return }
        settings.dictationLocaleIdentifier = identifier
        assistant.stopDictation()
    }

    private var polishMenu: some View {
        let alternative: PolishStyle = style == .note ? .prompt : .note
        let isBusy = assistant.isPolishing(targetID) || assistant.isDictating(targetID)
        // The main action is one click; the other rewrite style sits behind the chevron.
        return HStack(spacing: 0) {
            Button {
                polish(as: style)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11.5, weight: .medium))
                    Text(style.actionLabel).font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.trailing, 3)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fix and organize the text with a language model")

            Menu {
                Button(alternative == .prompt ? "Rewrite as an AI Prompt" : "Tidy Up as a Note") {
                    polish(as: alternative)
                }
                Divider()
                if let name = assistant.polisherResolution.polisher?.name {
                    Text("Using \(name)")
                } else {
                    Text("No model available")
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
            }
            .plainMenu()
            .help("More ways to rewrite")
        }
        .disabled(isBusy)
    }

    private func polish(as style: PolishStyle) {
        assistant.polish(targetID: targetID, text: text, style: style)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let proposal = assistant.proposal(for: targetID) {
            proposalView(proposal)
        } else if isPreviewing {
            MarkdownPreview(text: text) { line in
                text = MarkdownBlockParser.togglingCheckbox(atLine: line, in: text)
            }
        } else {
            MarkdownTextEditor(text: $text, isEditable: !assistant.isDictating(targetID), proxy: proxy)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    private func proposalView(_ proposal: TextAssistant.Proposal) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text("Suggested rewrite")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("· \(proposal.engineName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PillButton(title: "Discard", tint: .secondary) { assistant.discardProposal() }
                PillButton(title: "Apply", symbol: "checkmark", isProminent: true) {
                    assistant.applyProposal { text = $0 }
                    appState.showToast("Rewrite applied")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))

            MarkdownPreview(text: proposal.rewritten)
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusOverlay: some View {
        if let message = assistant.error(for: targetID) {
            NoticeBanner(text: message) { assistant.clearError() }
                .padding(8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if assistant.isPolishing(targetID) {
            statusPill {
                ProgressView().controlSize(.small)
                Text(style == .prompt ? "Refining the prompt…" : "Tidying up…")
                Button("Cancel") { assistant.cancelPolish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        } else if assistant.isDictating(targetID) {
            statusPill {
                switch assistant.dictationState {
                case .preparing(let status):
                    ProgressView().controlSize(.small)
                    Text(status)
                case .listening, .idle:
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text("Listening…")
                }
                Button("Stop") { assistant.stopDictation() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private func statusPill(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 7, content: content)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .padding(.bottom, 9)
    }
}
