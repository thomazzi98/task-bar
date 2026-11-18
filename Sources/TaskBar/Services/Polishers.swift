import Foundation
import FoundationModels
import TaskBarCore

/// Rewrites text with Apple's on-device language model. Free, private and offline, but it
/// requires macOS 26 with Apple Intelligence turned on.
@available(macOS 26.0, *)
struct AppleIntelligencePolisher: TextPolisher {
    /// The on-device model has a small context window, so long notes are rewritten in pieces.
    private static let chunkCharacters = 3500
    /// A prompt draft must be rewritten as a whole, or each piece would become its own prompt.
    private static let wholeTextLimit = 6000

    let name = "Apple Intelligence"

    static var availability: SystemLanguageModel.Availability {
        SystemLanguageModel.default.availability
    }

    /// Why the model cannot be used right now, or `nil` when it is ready.
    static var unavailableReason: String? {
        switch availability {
        case .available:
            nil
        case .unavailable(.appleIntelligenceNotEnabled):
            "Apple Intelligence is turned off. Enable it in System Settings > Apple Intelligence & Siri."
        case .unavailable(.deviceNotEligible):
            "This Mac does not support Apple Intelligence."
        case .unavailable(.modelNotReady):
            "The Apple Intelligence model is still downloading. Try again in a few minutes."
        case .unavailable:
            "Apple Intelligence is not available right now."
        }
    }

    func polish(_ text: String, style: PolishStyle) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TextPolishError.emptyInput }
        if let reason = Self.unavailableReason { throw TextPolishError.engineUnavailable(reason) }

        let pieces: [String]
        switch style {
        case .note:
            pieces = NoteChunker.chunks(of: trimmed, maxCharacters: Self.chunkCharacters)
        case .prompt:
            guard trimmed.count <= Self.wholeTextLimit else {
                throw TextPolishError.failed(
                    "This draft is too long for the on-device model. Choose Claude in Settings to refine it."
                )
            }
            pieces = [trimmed]
        }

        // Guardrails tuned for transforming user-provided text rather than generating content.
        let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
        var rewritten: [String] = []
        for piece in pieces {
            try Task.checkCancellation()
            // A fresh session per piece keeps earlier pieces out of the limited context.
            let session = LanguageModelSession(model: model, instructions: PolishInstructions.system(for: style))
            do {
                let response = try await session.respond(
                    to: PolishInstructions.userMessage(for: piece, style: style),
                    options: GenerationOptions(temperature: 0.2)
                )
                rewritten.append(PolishOutput.clean(response.content))
            } catch let error as LanguageModelSession.GenerationError {
                throw TextPolishError.failed(Self.describe(error))
            }
        }

        let result = rewritten.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !result.isEmpty else { throw TextPolishError.failed("The model returned an empty answer.") }
        return result
    }

    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            "The text is too long for the on-device model. Choose Claude in Settings for long texts."
        case .unsupportedLanguageOrLocale:
            "The on-device model does not support this language yet."
        case .guardrailViolation, .refusal:
            "The on-device model declined to rewrite this text."
        case .assetsUnavailable:
            "The Apple Intelligence model is not downloaded yet."
        case .rateLimited, .concurrentRequests:
            "The on-device model is busy. Try again in a moment."
        default:
            error.localizedDescription
        }
    }
}

/// Chooses the model used by "Tidy up", honouring the user's preference when it is available.
@MainActor
enum PolisherProvider {
    struct Resolution {
        var polisher: (any TextPolisher)?
        /// Shown when no engine is available, explaining how to enable one.
        var unavailableReason: String?
    }

    static func resolve(preference: PolisherPreference) -> Resolution {
        let apple = appleIntelligence()
        let claude = claudeCode()

        switch preference {
        case .appleIntelligence:
            return Resolution(polisher: apple.polisher, unavailableReason: apple.reason)
        case .claude:
            return Resolution(polisher: claude.polisher, unavailableReason: claude.reason)
        case .automatic:
            // On-device first: it is free, private and works offline.
            if let polisher = apple.polisher ?? claude.polisher {
                return Resolution(polisher: polisher, unavailableReason: nil)
            }
            return Resolution(
                polisher: nil,
                unavailableReason: "Turn on Apple Intelligence or install Claude Code to enable this. "
                    + "Everything else works without it."
            )
        }
    }

    /// One line per engine describing whether it can be used, for the settings screen.
    static func statusLines() -> [(name: String, isAvailable: Bool, detail: String)] {
        let apple = appleIntelligence()
        let claude = claudeCode()
        return [
            ("Apple Intelligence", apple.polisher != nil, apple.reason ?? "Ready · on-device, free"),
            ("Claude via Claude Code", claude.polisher != nil, claude.reason ?? "Ready · uses your Claude Code login")
        ]
    }

    private static func appleIntelligence() -> (polisher: (any TextPolisher)?, reason: String?) {
        guard #available(macOS 26.0, *) else {
            return (nil, "Apple Intelligence needs macOS 26 or later.")
        }
        if let reason = AppleIntelligencePolisher.unavailableReason { return (nil, reason) }
        return (AppleIntelligencePolisher(), nil)
    }

    private static func claudeCode() -> (polisher: (any TextPolisher)?, reason: String?) {
        guard let executable = ClaudeCLILocator.locate() else {
            return (nil, "Claude Code is not installed on this Mac.")
        }
        let projects = AppPaths.live().claudeProjectsDirectory
        return (ClaudeCLIPolisher(executable: executable, projectsDirectory: projects), nil)
    }
}
