import Foundation

/// Parakeet's unknown token.
///
/// Parakeet TDT v3's vocabulary has no quotation marks, nor @, &, #, brackets
/// or dashes: where it hears one of them it writes `<unk>`, which FluidAudio
/// copies into the transcript as is, usually right after a bare `▁` piece.
///
/// Dictated French mostly quotes a name or a phrase, so two standalone tokens
/// become « and » before Claude reads the transcript: handed the bare tokens,
/// Haiku sometimes dropped the words before the quote or quoted the whole
/// sentence. The tokens left over, alone or inside a word, go to Claude, which
/// picks the symbol from the context. Without Claude, or when it leaves one
/// in, `resolved` drops them.
nonisolated enum UnknownTokens {
    static let token = "<unk>"
    private static let boundary = "\u{2581}"

    static func containsUnknown(_ pieces: [String]) -> Bool {
        pieces.contains(where: isUnknownPiece)
    }

    /// One piece for each of `pieces`, so token timings stay aligned: paired
    /// tokens become guillemets of their own, `▁«` and `▁»`; the others are
    /// left for Claude.
    static func quoted(_ pieces: [String]) -> [String] {
        let unknowns = pieces.indices.filter { isUnknownPiece(pieces[$0]) }
        let quotes = unknowns.filter { !isInsideWord(at: $0, in: pieces) }
        let paired = quotes.prefix(quotes.count / 2 * 2)

        var quoted = pieces
        for (rank, index) in paired.enumerated() {
            let opening = rank.isMultiple(of: 2)
            quoted[index] = boundary + (opening ? "«" : "»")
            // « is followed by a space; » only when a word comes next.
            let next = index + 1
            guard next < quoted.count, let first = quoted[next].first, !startsWord(quoted[next]) else { continue }
            if opening || first.isLetter || first.isNumber { quoted[next] = boundary + quoted[next] }
        }
        return quoted
    }

    /// The transcript the pieces spell, as FluidAudio builds it, with the
    /// double spaces the quoted pieces can leave collapsed.
    static func text(fromPieces pieces: [String]) -> String {
        collapsed(pieces.joined().replacingOccurrences(of: boundary, with: " "))
    }

    /// `text` with no token left, for insertion: pairs become guillemets, the
    /// others are dropped.
    static func resolved(_ text: String) -> String {
        let ranges = text.ranges(of: token)
        guard !ranges.isEmpty else { return text }
        let quotes = ranges.filter { !isInsideWord($0, in: text) }
        let paired = Array(quotes.prefix(quotes.count / 2 * 2))

        var result = ""
        var cursor = text.startIndex
        for range in ranges {
            result += text[cursor..<range.lowerBound]
            let afterSpaces = text[range.upperBound...].drop { $0 == " " }
            let wordFollows = afterSpaces.first.map { $0.isLetter || $0.isNumber } ?? false
            cursor = range.upperBound

            guard let rank = paired.firstIndex(of: range) else {
                // Dropped: no space left before the punctuation that follows.
                if !wordFollows { trimTrailingSpaces(&result) }
                continue
            }
            let opening = rank.isMultiple(of: 2)
            trimTrailingSpaces(&result)
            if !result.isEmpty { result += " " }
            result += opening ? "«" : "»"
            cursor = afterSpaces.startIndex
            if opening || wordFollows { result += " " }
        }
        result += text[cursor...]
        return collapsed(result)
    }

    private static func isUnknownPiece(_ piece: String) -> Bool {
        piece.replacingOccurrences(of: boundary, with: "").trimmingCharacters(in: .whitespaces) == token
    }

    private static func startsWord(_ piece: String) -> Bool {
        piece.hasPrefix(boundary) || piece.hasPrefix(" ")
    }

    /// Letters on both sides with no word boundary: `moi<unk>exemple`.
    private static func isInsideWord(at index: Int, in pieces: [String]) -> Bool {
        guard !startsWord(pieces[index]), index > 0, index + 1 < pieces.count else { return false }
        let next = pieces[index + 1]
        guard let before = pieces[index - 1].last, let after = next.first, !startsWord(next) else { return false }
        return isAlphanumeric(before) && isAlphanumeric(after)
    }

    private static func isInsideWord(_ range: Range<String.Index>, in text: String) -> Bool {
        guard range.lowerBound > text.startIndex, range.upperBound < text.endIndex else { return false }
        return isAlphanumeric(text[text.index(before: range.lowerBound)]) && isAlphanumeric(text[range.upperBound])
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    private static func trimTrailingSpaces(_ text: inout String) {
        while text.last == " " { text.removeLast() }
    }

    private static func collapsed(_ text: String) -> String {
        text.replacing(/\ {2,}/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}
