import Foundation
import FoundationModels
import DictateKit

/// Why the on-device model cannot be used right now, in the user's words.
nonisolated enum AppleIntelligenceStatus: Equatable, Sendable {
    case available
    /// The Mac cannot run Apple Intelligence.
    case deviceNotEligible
    /// Off in System Settings.
    case notEnabled
    /// Being downloaded or not loaded yet.
    case modelNotReady
    case unavailable

    static var current: AppleIntelligenceStatus {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(.deviceNotEligible): .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): .notEnabled
        case .unavailable(.modelNotReady): .modelNotReady
        case .unavailable: .unavailable
        }
    }

    var isAvailable: Bool { self == .available }

    /// Nil when available.
    var explanation: String? {
        switch self {
        case .available: nil
        case .deviceNotEligible: String(localized: "Ce Mac ne prend pas en charge Apple Intelligence.")
        case .notEnabled: String(localized: "Apple Intelligence est désactivé dans les Réglages Système.")
        case .modelNotReady: String(localized: "Le modèle d'Apple Intelligence se télécharge ou se prépare : réessayez dans un instant.")
        case .unavailable: String(localized: "Apple Intelligence est indisponible.")
        }
    }
}

nonisolated enum AppleIntelligenceError: LocalizedError, Equatable {
    case unavailable(AppleIntelligenceStatus)
    /// The model declined the text: its own content filters.
    case refused
    case tooLong
    /// The reply has little left of the dictation: see `diverges`.
    case diverged

    var errorDescription: String? {
        switch self {
        case .unavailable(let status): status.explanation ?? String(localized: "Apple Intelligence est indisponible.")
        case .refused: String(localized: "Apple Intelligence a refusé ce texte.")
        case .tooLong: String(localized: "Dictée trop longue pour Apple Intelligence.")
        case .diverged: String(localized: "Apple Intelligence s'est écarté de la dictée : texte brut inséré.")
        }
    }
}

/// Cleans up transcripts with the on-device model behind Apple Intelligence:
/// nothing leaves the Mac, no account needed.
///
/// Each dictation gets its own session, so none sees the previous ones, and
/// the next session is warmed up as soon as one is used. The model's context
/// is small (about 4 000 tokens), so the field's surroundings are kept short
/// and dropped altogether when the prompt still does not fit.
final class AppleIntelligenceEnhancer: Enhancer {
    /// Characters of text kept on each side of the cursor: half of what
    /// Claude gets, the prompt and the dictation need the rest of the window.
    static let contextLength = 250

    private let systemPrompt: () -> String
    private var warm: LanguageModelSession?

    init(systemPrompt: @escaping () -> String) {
        self.systemPrompt = systemPrompt
    }

    static var status: AppleIntelligenceStatus { AppleIntelligenceStatus.current }

    /// Loads the model ahead of the next dictation, when it is available.
    func prewarm() {
        guard warm == nil, Self.status.isAvailable else { return }
        let session = LanguageModelSession(instructions: systemPrompt())
        session.prewarm()
        warm = session
    }

    /// Replaces the waiting session, e.g. after the vocabulary changed.
    func reset() {
        warm = nil
        prewarm()
    }

    func shutdown() {
        warm = nil
    }

    func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
        let status = Self.status
        guard status.isAvailable else { throw AppleIntelligenceError.unavailable(status) }
        let session = warm ?? LanguageModelSession(instructions: systemPrompt())
        warm = nil
        defer { prewarm() }
        do {
            return try await respond(session, to: Self.trimmed(context), transcription: transcription)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // A long field: the dictation alone usually fits.
            var bare = context
            bare.precedingText = nil
            bare.followingText = nil
            let retry = LanguageModelSession(instructions: systemPrompt())
            return try await respond(retry, to: bare, transcription: transcription)
        }
    }

    private func respond(
        _ session: LanguageModelSession, to context: DictationContext, transcription: Transcription
    ) async throws -> String {
        let message = PromptBuilder.userMessage(transcription: transcription, context: context)
        do {
            let response = try await session.respond(to: message, options: GenerationOptions(temperature: 0))
            try Task.checkCancellation()
            let text = DoubtfulWords.strip(PromptBuilder.cleanedText(from: response.content))
            guard !Self.diverges(text, from: transcription.text) else { throw AppleIntelligenceError.diverged }
            return text
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: throw AppleIntelligenceError.refused
            case .exceededContextWindowSize: throw error
            case .assetsUnavailable: throw AppleIntelligenceError.unavailable(.modelNotReady)
            default: throw error
            }
        }
    }

    /// Dictations shorter than this are not judged: fixing one misheard word
    /// already changes half of a two-word one.
    static let minimumJudgedWords = 3
    /// Word error rate of the reply against the transcript beyond which the
    /// reply is no longer a cleanup. On 1 512 corpus dictations (2026-11-03)
    /// the on-device model's six bad replies ("/", "/ CI/CD", the field's text
    /// instead of the dictation) were all at 1.0 or more, its good ones at 0.5
    /// or less.
    static let maximumWordErrorRate = 0.6

    /// The small model sometimes answers the field's text, or a symbol from it,
    /// instead of cleaning up the dictation: the raw transcript is better then.
    static func diverges(_ reply: String, from transcript: String) -> Bool {
        let transcriptWords = WordErrorRate.words(in: transcript)
        // A dictated emoji takes the place of its words, which the error rate
        // would count as deleted: they are forgiven, the trigger included.
        let emojis = DictatedEmoji.isRequested(in: transcript) ? DictatedEmoji.count(in: reply) : 0
        if WordErrorRate.words(in: reply).isEmpty { return !transcriptWords.isEmpty && emojis == 0 }
        guard transcriptWords.count >= minimumJudgedWords else { return false }
        let count = WordErrorRate.count(reference: transcript, hypothesis: reply)
        let errors = max(0, count.errors - emojis * wordsPerEmoji)
        return Double(errors) / Double(count.referenceWords) > maximumWordErrorRate
    }

    /// The words a dictated emoji may replace: its trigger and a description
    /// such as "qui pleure de rire".
    static let wordsPerEmoji = 5

    /// The context cut down to what the small window can take.
    static func trimmed(_ context: DictationContext) -> DictationContext {
        var trimmed = context
        trimmed.precedingText = context.precedingText.map { String($0.suffix(contextLength)) }
        trimmed.followingText = context.followingText.map { String($0.prefix(contextLength)) }
        return trimmed
    }
}
