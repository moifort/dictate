import Foundation

/// Emojis said aloud: "émoji fusée" or "smiley qui pleure de rire" becomes
/// 🚀 or 😂. The reviewer picks the character; this knows how to spot them.
nonisolated enum DictatedEmoji {
    /// Words that announce an emoji, lowercased and without accents. Plurals
    /// and "émoticône" match too: these are prefixes.
    static let triggers = ["emoji", "smiley", "emoticon"]

    /// Whether the transcript names an emoji to insert.
    static func isRequested(in transcript: String) -> Bool {
        let normalization = WordErrorRate.Normalization(foldDiacritics: true)
        return WordErrorRate.words(in: transcript, normalization: normalization)
            .contains { word in triggers.contains { word.hasPrefix($0) } }
    }

    /// The emojis in `text`. Digits, # and * are emoji scalars too, but only
    /// count when drawn as one (a keycap, or followed by the emoji selector).
    static func count(in text: String) -> Int {
        text.filter { character in
            guard let first = character.unicodeScalars.first else { return false }
            return first.properties.isEmojiPresentation
                || (first.properties.isEmoji && character.unicodeScalars.count > 1)
        }.count
    }
}
