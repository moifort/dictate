import Testing
@testable import Dictate

struct PromptBuilderTests {
    @Test func systemPromptListsVocabulary() {
        let prompt = PromptBuilder.systemPrompt(vocabulary: ["CI/CD", "rebase"])
        #expect(prompt.contains("CI/CD"))
        #expect(prompt.contains("rebase"))
    }

    @Test func systemPromptOmitsVocabularySectionWhenEmpty() {
        let prompt = PromptBuilder.systemPrompt(vocabulary: [])
        #expect(!prompt.contains("<vocabulary>"))
    }

    @Test func userMessageWrapsTranscriptAndCarriesCategory() {
        let message = PromptBuilder.userMessage(transcript: "fais un push", category: .code)
        #expect(message.contains("<dictation>\nfais un push\n</dictation>"))
        #expect(message.contains("<context>code</context>"))
    }

    @Test(arguments: [AppCategory.code, .mail, .chat, .other])
    func everyCategoryIsDescribedInSystemPrompt(category: AppCategory) {
        #expect(PromptBuilder.systemPrompt(vocabulary: []).contains("- \(category.rawValue):"))
    }
}
