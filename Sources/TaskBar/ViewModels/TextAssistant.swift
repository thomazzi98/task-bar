import Foundation
import Observation
import TaskBarCore

/// Voice dictation and "Tidy up" for whichever text editor is active.
///
/// Editors identify themselves with a `targetID`, so one assistant serves every notes field
/// while guaranteeing that only one dictation or rewrite runs at a time.
@MainActor
@Observable
final class TextAssistant {
    enum DictationState: Equatable {
        case idle
        /// Asking for permission or loading the speech model.
        case preparing(String)
        case listening
    }

    /// A rewrite waiting for the user to accept or discard it.
    struct Proposal: Equatable {
        var targetID: String
        var original: String
        var rewritten: String
        var style: PolishStyle
        var engineName: String
    }

    private(set) var dictationState: DictationState = .idle
    private(set) var dictationTargetID: String?
    private(set) var polishingTargetID: String?
    private(set) var proposal: Proposal?
    private(set) var errorMessage: String?
    private(set) var errorTargetID: String?
    /// Text as it was before the last accepted rewrite, per editor, for one-step revert.
    private(set) var revertSnapshots: [String: String] = [:]

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let appState: AppState
    @ObservationIgnored private var engine: (any DictationEngine)?
    @ObservationIgnored private var polishTask: Task<Void, Never>?
    @ObservationIgnored private var dictationWriter: ((String) -> Void)?
    @ObservationIgnored private var dictationHead = ""
    @ObservationIgnored private var dictationTail = ""

    init(settings: SettingsStore, appState: AppState) {
        self.settings = settings
        self.appState = appState
    }

    // MARK: Queries

    func isDictating(_ targetID: String) -> Bool {
        dictationTargetID == targetID && dictationState != .idle
    }

    func isPolishing(_ targetID: String) -> Bool {
        polishingTargetID == targetID
    }

    func proposal(for targetID: String) -> Proposal? {
        proposal?.targetID == targetID ? proposal : nil
    }

    func error(for targetID: String) -> String? {
        errorTargetID == targetID ? errorMessage : nil
    }

    func canRevert(_ targetID: String) -> Bool {
        revertSnapshots[targetID] != nil
    }

    /// The engine "Tidy up" would use right now, or why none is available.
    var polisherResolution: PolisherProvider.Resolution {
        PolisherProvider.resolve(preference: settings.polisherPreference)
    }

    // MARK: Dictation

    /// Starts dictating into `text` at `insertionOffset` (a UTF-16 offset; `nil` appends), or
    /// stops when this editor is already dictating. `write` receives the updated text.
    func toggleDictation(
        targetID: String,
        text: String,
        insertionOffset: Int?,
        write: @escaping (String) -> Void
    ) {
        if dictationState != .idle {
            let wasThisTarget = dictationTargetID == targetID
            stopDictation()
            if wasThisTarget { return }
        }
        clearError()

        let (head, tail) = Self.split(text, atUTF16Offset: insertionOffset)
        dictationHead = head
        dictationTail = tail
        dictationWriter = write
        dictationTargetID = targetID
        dictationState = .preparing("Preparing…")

        Task { await beginDictation(targetID: targetID) }
    }

    func stopDictation() {
        guard dictationState != .idle else { return }
        guard let engine else {
            // Still asking for permission or loading: nothing to flush.
            finishDictation()
            return
        }
        self.engine = nil
        let targetID = dictationTargetID
        dictationState = .preparing("Finishing…")
        Task { [weak self] in
            // The recogniser revises its last words when the audio ends; wait for them so the
            // final text is what stays in the note.
            await engine.stop()
            guard let self, self.dictationTargetID == targetID else { return }
            self.finishDictation()
        }
    }

    private func beginDictation(targetID: String) async {
        guard AppBundle.isBundled else {
            return failDictation(DictationError.needsBundledApp.localizedDescription, targetID: targetID)
        }

        // System permission dialogs take focus away; keep the popover from closing meanwhile.
        let permission: DictationError? = await appState.holdingOpen {
            guard await DictationPermissions.requestMicrophone() else { return .microphoneDenied }
            if #unavailable(macOS 26.0) {
                guard await DictationPermissions.requestSpeechRecognition() else { return .speechRecognitionDenied }
            }
            return nil
        }
        if let permission {
            return failDictation(permission.localizedDescription, targetID: targetID)
        }
        // The user may have cancelled while a permission prompt was up.
        guard dictationTargetID == targetID, dictationState != .idle else { return }

        let engine = Dictation.makeEngine()
        self.engine = engine
        do {
            try await engine.start(
                locale: settings.dictationLocale,
                onStatus: { [weak self] status in
                    guard let self, self.dictationTargetID == targetID else { return }
                    self.dictationState = .preparing(status)
                },
                onUpdate: { [weak self] transcript in
                    self?.applyTranscript(transcript, targetID: targetID)
                },
                onFinish: { [weak self] failure in
                    guard let self, self.dictationTargetID == targetID else { return }
                    if let failure { self.setError(failure, targetID: targetID) }
                    self.engine = nil
                    self.finishDictation()
                }
            )
            guard dictationTargetID == targetID, self.engine != nil else {
                // Stopped while the engine was starting up.
                await engine.stop()
                return
            }
            dictationState = .listening
            Log.voice.info("dictation started (\(self.settings.dictationLocale.identifier(.bcp47), privacy: .public))")
        } catch {
            self.engine = nil
            failDictation(error.localizedDescription, targetID: targetID)
        }
    }

    private func applyTranscript(_ transcript: DictationTranscript, targetID: String) {
        guard dictationTargetID == targetID else { return }
        dictationWriter?(Self.compose(head: dictationHead, spoken: transcript.text, tail: dictationTail))
    }

    private func failDictation(_ message: String, targetID: String) {
        Log.voice.error("dictation failed: \(message, privacy: .public)")
        setError(message, targetID: targetID)
        finishDictation()
    }

    private func finishDictation() {
        dictationState = .idle
        dictationTargetID = nil
        dictationWriter = nil
        dictationHead = ""
        dictationTail = ""
    }

    // MARK: Tidy up

    func polish(targetID: String, text: String, style: PolishStyle) {
        guard polishingTargetID == nil else { return }
        clearError()
        proposal = nil

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return setError(TextPolishError.emptyInput.localizedDescription, targetID: targetID)
        }
        let resolution = polisherResolution
        guard let polisher = resolution.polisher else {
            return setError(resolution.unavailableReason ?? "No model is available.", targetID: targetID)
        }

        polishingTargetID = targetID
        polishTask = Task { [weak self] in
            let outcome: Result<String, Error>
            do {
                outcome = .success(try await polisher.polish(trimmed, style: style))
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled, self.polishingTargetID == targetID else { return }
            self.polishingTargetID = nil

            switch outcome {
            case .success(let rewritten) where rewritten == trimmed:
                self.setError("Nothing to change: the text already reads well.", targetID: targetID)
            case .success(let rewritten):
                self.proposal = Proposal(
                    targetID: targetID,
                    original: text,
                    rewritten: rewritten,
                    style: style,
                    engineName: polisher.name
                )
            case .failure(let error):
                self.setError(error.localizedDescription, targetID: targetID)
            }
        }
    }

    func cancelPolish() {
        polishTask?.cancel()
        polishTask = nil
        polishingTargetID = nil
    }

    /// Accepts the pending rewrite, remembering the original so it can be restored.
    func applyProposal(write: (String) -> Void) {
        guard let proposal else { return }
        revertSnapshots[proposal.targetID] = proposal.original
        write(proposal.rewritten)
        self.proposal = nil
    }

    func discardProposal() {
        proposal = nil
    }

    /// Restores the text from before the last accepted rewrite.
    func revert(targetID: String, write: (String) -> Void) {
        guard let original = revertSnapshots.removeValue(forKey: targetID) else { return }
        write(original)
    }

    /// Drops per-editor state when its editor goes away.
    func forget(targetID: String) {
        revertSnapshots[targetID] = nil
        if proposal?.targetID == targetID { proposal = nil }
        if polishingTargetID == targetID { cancelPolish() }
        if dictationTargetID == targetID { stopDictation() }
        if errorTargetID == targetID { clearError() }
    }

    func clearError() {
        errorMessage = nil
        errorTargetID = nil
    }

    private func setError(_ message: String, targetID: String) {
        errorMessage = message
        errorTargetID = targetID
    }

    // MARK: Text composition

    /// Splits `text` at a UTF-16 offset, as reported by `NSTextView`.
    static func split(_ text: String, atUTF16Offset offset: Int?) -> (head: String, tail: String) {
        guard let offset, offset >= 0, offset < text.utf16.count,
              let index = String.Index(utf16Offset: offset, in: text).samePosition(in: text)
        else { return (text, "") }
        return (String(text[..<index]), String(text[index...]))
    }

    /// Inserts spoken text between `head` and `tail`, adding the spaces a typist would.
    static func compose(head: String, spoken: String, tail: String) -> String {
        let words = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return head + tail }

        let needsLeadingSpace = head.last.map { !$0.isWhitespace } ?? false
        let needsTrailingSpace = tail.first.map { !$0.isWhitespace && !$0.isPunctuation } ?? false
        return head + (needsLeadingSpace ? " " : "") + words + (needsTrailingSpace ? " " : "") + tail
    }
}
