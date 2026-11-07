import Foundation
import Testing
@testable import Dictate
import DictateKit

/// Routing only: the on-device model needs Apple Intelligence, which CI
/// does not have, so the Apple side is exercised through fakes and its
/// context trimming.
@MainActor
struct SelectedEnhancerTests {
    private struct FakeError: Error {}

    private final class FakeEnhancer: WarmableEnhancer {
        let reply: Result<String, Error>
        private(set) var calls = 0
        private(set) var warm = false

        init(_ reply: Result<String, Error>) { self.reply = reply }

        func prewarm() { warm = true }
        func reset() { warm = true }
        func shutdown() { warm = false }

        func enhance(_ transcription: Transcription, context: DictationContext) async throws -> String {
            calls += 1
            return try reply.get()
        }
    }

    private func make(
        reviewer: Reviewer, online: Bool = true, appleAvailable: Bool = true,
        apple: FakeEnhancer = FakeEnhancer(.success("apple")),
        claude: FakeEnhancer = FakeEnhancer(.success("claude")),
        others: [Reviewer: any Enhancer] = [.openAI: FakeEnhancer(.success("openai")), .gemini: FakeEnhancer(.success("gemini"))]
    ) -> (SelectedEnhancer, apple: FakeEnhancer, claude: FakeEnhancer) {
        let enhancer = SelectedEnhancer(
            reviewer: { reviewer }, isOnline: { online }, appleAvailable: { appleAvailable },
            apple: apple, claude: claude, others: others
        )
        return (enhancer, apple, claude)
    }

    @Test func withoutAReviewerEnhancementFails() async {
        let (enhancer, _, _) = make(reviewer: Reviewer.none)
        await #expect(throws: SelectedEnhancerError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func theChosenReviewerIsAsked() async throws {
        let (claude, _, _) = make(reviewer: .claude)
        #expect(try await claude.enhance(transcript: "x", context: DictationContext()) == "claude")
        let (apple, _, _) = make(reviewer: .apple)
        #expect(try await apple.enhance(transcript: "x", context: DictationContext()) == "apple")
    }

    @Test func offlineClaudeGivesWayToAppleIntelligence() async throws {
        let (enhancer, _, claude) = make(reviewer: .claude, online: false)
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(claude.calls == 0)
        #expect(enhancer.effectiveReviewer == .apple)
    }

    @Test func theReviewerActuallyUsedIsRemembered() async throws {
        let (chosen, _, _) = make(reviewer: .claude)
        #expect(chosen.lastUsed == nil)
        _ = try await chosen.enhance(transcript: "x", context: DictationContext())
        #expect(chosen.lastUsed == .claude)
        let (offline, _, _) = make(reviewer: .claude, online: false)
        _ = try await offline.enhance(transcript: "x", context: DictationContext())
        #expect(offline.lastUsed == .apple)
        let (failing, _, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(FakeError())))
        _ = try await failing.enhance(transcript: "x", context: DictationContext())
        #expect(failing.lastUsed == .apple)
    }

    @Test func offlineWithoutAppleIntelligenceStillAsksClaude() async throws {
        let (enhancer, _, claude) = make(reviewer: .claude, online: false, appleAvailable: false)
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "claude")
        #expect(claude.calls == 1)
        #expect(enhancer.effectiveReviewer == .claude)
    }

    @Test func aFailingClaudeFallsBackToAppleIntelligence() async throws {
        let (enhancer, apple, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(FakeError())))
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(apple.calls == 1)
    }

    @Test func aFailingClaudeWithoutAppleIntelligenceFails() async {
        let (enhancer, apple, _) = make(reviewer: .claude, appleAvailable: false, claude: FakeEnhancer(.failure(FakeError())))
        await #expect(throws: FakeError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
        #expect(apple.calls == 0)
    }

    @Test func aSignedOutClaudeIsRememberedUntilItAnswersAgain() async throws {
        let signedOut = FakeEnhancer(.failure(ClaudeCLIError.failed("Failed to authenticate: OAuth session expired")))
        let (enhancer, _, _) = make(reviewer: .claude, claude: signedOut)
        #expect(!enhancer.isClaudeDisconnected)
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(enhancer.isClaudeDisconnected)

        let (other, _, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(FakeError())))
        _ = try await other.enhance(transcript: "x", context: DictationContext())
        #expect(!other.isClaudeDisconnected)
    }

    @Test func aRefusedAPIKeyShowsLikeASignedOutClaude() async throws {
        let (enhancer, _, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(APIReviewError.invalidKey(.anthropic))))
        #expect(try await enhancer.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(enhancer.isClaudeDisconnected)

        let (limited, _, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(APIReviewError.rateLimited(.anthropic))))
        #expect(try await limited.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(!limited.isClaudeDisconnected)
    }

    @Test func openAIAndGeminiAreAskedAndFallBackLikeClaude() async throws {
        let (openAI, _, claude) = make(reviewer: .openAI)
        #expect(try await openAI.enhance(transcript: "x", context: DictationContext()) == "openai")
        #expect(claude.calls == 0)
        let (gemini, _, _) = make(reviewer: .gemini)
        #expect(try await gemini.enhance(transcript: "x", context: DictationContext()) == "gemini")

        let (offline, _, _) = make(reviewer: .gemini, online: false)
        #expect(offline.effectiveReviewer == .apple)
        #expect(try await offline.enhance(transcript: "x", context: DictationContext()) == "apple")

        let (refused, _, _) = make(reviewer: .openAI, others: [.openAI: FakeEnhancer(.failure(APIReviewError.invalidKey(.openAI)))])
        #expect(try await refused.enhance(transcript: "x", context: DictationContext()) == "apple")
        #expect(refused.lastUsed == .apple)
        // The indicator's warning is about Claude's sign-in only.
        #expect(!refused.isClaudeDisconnected)
    }

    @Test func aSignedOutClaudeWithoutAppleIntelligenceIsRememberedToo() async {
        let signedOut = FakeEnhancer(.failure(ClaudeCLIError.failed("Please run /login")))
        let (enhancer, _, _) = make(reviewer: .claude, appleAvailable: false, claude: signedOut)
        await #expect(throws: ClaudeCLIError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
        #expect(enhancer.isClaudeDisconnected)
    }

    @Test func aCancelledClaudeIsNotRetriedOnApple() async {
        let (enhancer, apple, _) = make(reviewer: .claude, claude: FakeEnhancer(.failure(CancellationError())))
        await #expect(throws: CancellationError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
        #expect(apple.calls == 0)
    }

    @Test func onlyTheEffectiveReviewerIsWarm() {
        let (online, apple, claude) = make(reviewer: .claude)
        online.reset()
        #expect(claude.warm && !apple.warm)
        let (offline, apple2, claude2) = make(reviewer: .claude, online: false)
        offline.reset()
        #expect(apple2.warm && !claude2.warm)
    }

    @Test func theFieldIsCutDownToTheSmallContextWindow() {
        let long = String(repeating: "a", count: 500)
        let context = DictationContext(precedingText: long, followingText: long)
        let trimmed = AppleIntelligenceEnhancer.trimmed(context)
        #expect(trimmed.precedingText?.count == AppleIntelligenceEnhancer.contextLength)
        #expect(trimmed.followingText?.count == AppleIntelligenceEnhancer.contextLength)
        #expect(AppleIntelligenceEnhancer.trimmed(DictationContext()).precedingText == nil)
    }

    /// Apple Intelligence replies seen on 2026-11-03 for correct transcripts.
    @Test(arguments: [
        ("Comment te connectes-tu à Centrée ici ?", "/"),
        ("Tu peux utiliser la clé qui se trouve dans Vinarium pour accéder à Ocentri.", "/ CI/CD"),
        (
            "Ce problème est géré visuellement.",
            "Regarde le Sentry, il y a un bug qui vient de tomber. Dis-moi qui l'a généré, si c'est toi."
        ),
        ("Oui.", ""),
    ])
    func aReplyThatLeftTheDictationIsRejected(transcript: String, reply: String) {
        #expect(AppleIntelligenceEnhancer.diverges(reply, from: transcript))
    }

    @Test(arguments: [
        ("Un, deux, trois, j'irai au soleil.", "1. 2. 3. j'irai au soleil."),
        ("Bonjour, j'aimerais que Milipchou m'écoute et ceit plus intelligent.", "Bonjour, j'aimerais que Milipchou m'écoute et soit plus intelligent."),
        ("Moi je vais travailler uniquement sur la partie robot.", "Je vais travailler uniquement sur la partie robot."),
        // Too short to judge: a single fixed word is most of it.
        ("Votre raz.", "Votre projet."),
        ("Jouez.", "Joué."),
    ])
    func aCleanedUpDictationIsKept(transcript: String, reply: String) {
        #expect(!AppleIntelligenceEnhancer.diverges(reply, from: transcript))
    }

    @Test func aShortFieldIsKeptWhole() {
        let context = DictationContext(precedingText: "Salut Guillaume, ", followingText: " merci.")
        #expect(AppleIntelligenceEnhancer.trimmed(context) == context)
    }
}
