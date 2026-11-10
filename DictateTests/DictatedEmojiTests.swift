import Testing

@testable import Dictate

struct DictatedEmojiTests {
    @Test(arguments: ["Émoji fusée", "un smiley qui rit", "deux emojis cœur", "Émoticône clin d'œil"])
    func aTriggerWordAsksForAnEmoji(transcript: String) {
        #expect(DictatedEmoji.isRequested(in: transcript))
    }

    @Test func aSentenceWithoutTriggerAsksForNone() {
        #expect(!DictatedEmoji.isRequested(in: "Déploie la branche sur staging."))
    }

    @Test(arguments: [("🚀", 1), ("❤️ et 👍🏽", 2), ("1️⃣", 1), ("Prix : 100 € #1 *", 0), ("Super 😂😂", 2)])
    func emojisAreCountedAsDrawn(text: String, expected: Int) {
        #expect(DictatedEmoji.count(in: text) == expected)
    }
}
