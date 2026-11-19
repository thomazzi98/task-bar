import Testing
@testable import TaskBarCore

@Suite("Dictation locale resolver")
struct DictationLocaleResolverTests {
    private let supported = ["en-US", "en-GB", "pt-BR", "es-ES", "fr-FR"]

    @Test("Picks the first preferred language the engine supports")
    func firstSupportedPreference() {
        #expect(DictationLocaleResolver.resolve(preferred: ["de-DE", "pt-BR", "en-US"], supported: supported) == "pt-BR")
    }

    @Test("English UI with Portuguese among the preferences dictates in the first preferred language")
    func portugueseAfterEnglishUI() {
        #expect(DictationLocaleResolver.resolve(preferred: ["pt-BR", "en-US"], supported: supported) == "pt-BR")
        #expect(DictationLocaleResolver.resolve(preferred: ["en-US", "pt-BR"], supported: supported) == "en-US")
    }

    @Test("Matches case and underscore differences")
    func normalisesIdentifiers() {
        #expect(DictationLocaleResolver.resolve(preferred: ["pt_br"], supported: supported) == "pt-BR")
    }

    @Test("Falls back to a supported locale in the same language")
    func sameLanguageFallback() {
        #expect(DictationLocaleResolver.resolve(preferred: ["pt-PT"], supported: supported) == "pt-BR")
    }

    @Test("Returns nil when no preference is supported")
    func noMatch() {
        #expect(DictationLocaleResolver.resolve(preferred: ["ja-JP", ""], supported: supported) == nil)
        #expect(DictationLocaleResolver.resolve(preferred: [], supported: supported) == nil)
        #expect(DictationLocaleResolver.resolve(preferred: ["pt-BR"], supported: []) == nil)
    }
}
