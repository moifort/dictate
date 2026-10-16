import Foundation

/// Parakeet's unknown token, resolved before anyone reads the transcript.
///
/// Parakeet TDT v3's vocabulary has no quotation marks, nor @, &, #, brackets
/// or dashes: where it hears one of them it writes `<unk>`, which FluidAudio
/// copies into the text as is, usually right after a bare `▁` piece. Dictated
/// French quotes a name or a phrase far more often than it needs the other
/// characters, so standalone tokens alternate between « and », with French
/// spacing. A token glued inside a word, or left unpaired, is dropped: what it
/// stood for cannot be told.
nonisolated enum UnknownTokens {
    static let token = "<unk>"
    private static let boundary = "\u{2581}"

    static func containsUnknown(_ pieces: [String]) -> Bool {
        pieces.contains(where: isUnknown)
    }

    /// One piece for each of `pieces`, so token timings stay aligned: the
    /// unknown tokens become guillemets of their own, `▁«` and `▁»`, or empty
    /// pieces when dropped.
    static func resolved(_ pieces: [String]) -> [String] {
        let unknowns = pieces.indices.filter { isUnknown(pieces[$0]) }
        guard !unknowns.isEmpty else { return pieces }
        let quotes = unknowns.filter { !isInsideWord(at: $0, in: pieces) }
        let paired = quotes.prefix(quotes.count / 2 * 2)

        var resolved = pieces
        for index in unknowns { resolved[index] = "" }
        for (rank, index) in paired.enumerated() {
            let opening = rank.isMultiple(of: 2)
            resolved[index] = boundary + (opening ? "«" : "»")
            // « is followed by a space; » only when a word comes next.
            let next = index + 1
            guard next < resolved.count, let first = resolved[next].first, !startsWord(resolved[next]) else { continue }
            if opening || first.isLetter || first.isNumber { resolved[next] = boundary + resolved[next] }
        }
        return resolved
    }

    /// The transcript the pieces spell, as FluidAudio builds it, with the
    /// double spaces the resolved pieces can leave collapsed.
    static func text(fromPieces pieces: [String]) -> String {
        collapsed(pieces.joined().replacingOccurrences(of: boundary, with: " "))
    }

    /// `text` without its unknown tokens, for when no token timings came
    /// with it.
    static func stripped(_ text: String) -> String {
        guard text.contains(token) else { return text }
        return collapsed(text.replacingOccurrences(of: " " + token, with: "").replacingOccurrences(of: token, with: ""))
    }

    private static func isUnknown(_ piece: String) -> Bool {
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
        return (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
    }

    private static func collapsed(_ text: String) -> String {
        text.replacing(/\ {2,}/, with: " ").trimmingCharacters(in: .whitespaces)
    }
}
