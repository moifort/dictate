import Foundation
import Testing
@testable import Dictate

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
        claude: FakeEnhancer = FakeEnhancer(.success("claude"))
    ) -> (SelectedEnhancer, apple: FakeEnhancer, claude: FakeEnhancer) {
        let enhancer = SelectedEnhancer(
            reviewer: { reviewer }, isOnline: { online }, appleAvailable: { appleAvailable },
            apple: apple, claude: claude
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

    @Test func aShortFieldIsKeptWhole() {
        let context = DictationContext(precedingText: "Salut Guillaume, ", followingText: " merci.")
        #expect(AppleIntelligenceEnhancer.trimmed(context) == context)
    }
}
