import Foundation
import Testing
@testable import Dictate

/// Routing only: the on-device model needs Apple Intelligence, which CI
/// does not have, so the Apple side is exercised through its context trimming.
@MainActor
struct SelectedEnhancerTests {
    @Test func withoutAReviewerEnhancementFails() async {
        let enhancer = SelectedEnhancer(
            reviewer: { Reviewer.none },
            apple: AppleIntelligenceEnhancer(systemPrompt: { "prompt" }),
            claude: ClaudeCLIEnhancer(locate: { nil }, systemPrompt: { "prompt" })
        )
        await #expect(throws: SelectedEnhancerError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func claudeIsAskedWhenChosen() async {
        let enhancer = SelectedEnhancer(
            reviewer: { .claude },
            apple: AppleIntelligenceEnhancer(systemPrompt: { "prompt" }),
            claude: ClaudeCLIEnhancer(locate: { nil }, systemPrompt: { "prompt" })
        )
        await #expect(throws: ClaudeCLIError.notFound) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
    }

    @Test func appleIsAskedWhenChosen() async {
        let enhancer = SelectedEnhancer(
            reviewer: { .apple },
            apple: AppleIntelligenceEnhancer(systemPrompt: { "prompt" }),
            claude: ClaudeCLIEnhancer(locate: { nil }, systemPrompt: { "prompt" })
        )
        guard !AppleIntelligenceEnhancer.status.isAvailable else { return }
        await #expect(throws: AppleIntelligenceError.self) {
            try await enhancer.enhance(transcript: "x", context: DictationContext())
        }
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
