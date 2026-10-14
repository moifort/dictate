import Foundation

/// A word of a text, as the vocabulary suggestions see it.
nonisolated struct TermToken: Equatable, Sendable {
    /// The word without the punctuation around it nor a French elision: "l'API," is "API".
    let text: String
    /// Lowercased, accents folded, letters and digits only: what tells two words apart.
    let key: String
    /// First word of the text, of a line or after `.`, `!`, `?` or `…`: a capital there says nothing.
    let sentenceInitial: Bool
}

/// Splits text into words and tells which ones look like vocabulary terms.
nonisolated enum TermTokenizer {
    static func tokens(in text: String) -> [TermToken] {
        var tokens: [TermToken] = []
        var boundary = true
        var chunk = ""

        func flush() {
            guard !chunk.isEmpty else { return }
            defer { chunk = "" }
            let text = word(in: chunk)
            let key = key(of: text)
            if !key.isEmpty {
                tokens.append(TermToken(text: text, key: key, sentenceInitial: boundary))
                boundary = false
            }
            if endsSentence(chunk) { boundary = true }
        }

        for character in text {
            if character.isWhitespace {
                flush()
                if character.isNewline { boundary = true }
            } else {
                chunk.append(character)
            }
        }
        flush()
        return tokens
    }

    /// Whether the word is worth spelling out to Claude: a name, an acronym,
    /// mixed case, digits, or a technical token like `node.js` or `C++`.
    static func looksLikeTerm(_ token: TermToken) -> Bool {
        let text = token.text
        // "C++" and "C#" have a single letter of key.
        if text.hasSuffix("++") || text.hasSuffix("#"), text.contains(where: \.isLetter) { return true }
        guard token.key.count >= 2, text.contains(where: \.isLetter), !stopWords.contains(token.key) else { return false }
        // Contractions ("I'm", "don't"), emails and links are not terms.
        guard !text.contains(where: { "'’@".contains($0) }), !text.contains("://") else { return false }
        if text.contains(where: \.isNumber) { return true }
        if text.dropFirst().contains(where: \.isUppercase) { return true }
        if isTechnical(text) { return true }
        return text.first?.isUppercase == true && !token.sentenceInitial
    }

    /// `node.js`, `snake_case`: a dot or an underscore inside the word, with
    /// at least two letters on one side, unlike "e.g".
    private static func isTechnical(_ text: String) -> Bool {
        let parts = text.split(whereSeparator: { $0 == "." || $0 == "_" })
        return parts.count >= 2 && parts.contains { $0.count >= 2 }
    }

    /// Lowercase key of a word or phrase, for comparisons that ignore case, accents and punctuation.
    static func key(of text: String) -> String {
        String(String.UnicodeScalarView(
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        ))
    }

    /// The chunk without surrounding punctuation, French elision or English possessive.
    private static func word(in chunk: String) -> String {
        var word = Substring(chunk)
        while let first = word.first, isEdge(first) { word.removeFirst() }
        // "C++" and "C#" keep their tail.
        while let last = word.last, isEdge(last), last != "+", last != "#" { word.removeLast() }
        if let apostrophe = word.firstIndex(where: { $0 == "'" || $0 == "’" }) {
            let head = word[..<apostrophe].lowercased()
            let tail = word[word.index(after: apostrophe)...]
            if elisions.contains(head) {
                word = tail
            } else if tail == "s" {
                word = word[..<apostrophe]
            }
        }
        return String(word)
    }

    private static func isEdge(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }

    private static func endsSentence(_ chunk: String) -> Bool {
        let trimmed = chunk.reversed().drop { "\"'»”’)]*".contains($0) }
        return trimmed.first.map { ".!?…".contains($0) } ?? false
    }

    private static let elisions: Set<String> = [
        "l", "d", "j", "m", "n", "s", "t", "c", "qu", "jusqu", "lorsqu", "puisqu",
    ]

    /// Capitalised often, but never a term worth adding.
    private static let stopWords: Set<String> = [
        "ok", "okay", "ps", "fyi", "tv", "mr", "mrs", "ms", "dr", "mme", "mlle", "monsieur", "madame",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    ]
}

/// A word or short phrase the user replaced in a dictation, a few seconds after it was pasted.
nonisolated struct TermCorrection: Equatable, Sendable {
    /// What was pasted, e.g. "cloud".
    let wrong: String
    /// What the user wrote instead, e.g. "Claude".
    let right: String
}

/// Finds the terms the user fixed in a pasted dictation.
///
/// Both texts are aligned word by word, comparing keys (case, accents and
/// punctuation ignored): those edits are style, not vocabulary. Each run of
/// replaced words is a candidate when it is short, when the new words look
/// like a term, and when they still resemble the old ones: a mis-heard name
/// is close in spelling, a change of mind is not. Deletions, additions and
/// rewrites of most of the text are left alone.
nonisolated enum CorrectedTerms {
    static let maxWrongWords = 4
    static let maxRightWords = 3
    /// Edit distance over the longer key, beyond which the words are unrelated.
    static let maxDistanceRatio = 0.7
    /// Past this many words on each side, the alignment is not worth its cost.
    static let maxWords = 400

    static func corrections(inserted: String, corrected: String) -> [TermCorrection] {
        let old = TermTokenizer.tokens(in: inserted)
        let new = TermTokenizer.tokens(in: corrected)
        guard !old.isEmpty, !new.isEmpty, old.count <= maxWords, new.count <= maxWords else { return [] }

        let oldKeys = old.map(\.key), newKeys = new.map(\.key)
        let table = lcsTable(oldKeys, newKeys)
        let unmatched = old.count - table[0][0]
        // A rewrite of most of the text says nothing about any single word.
        guard unmatched <= max(3, old.count / 2) else { return [] }

        return replacedRuns(oldKeys, newKeys, table: table).compactMap { hunk -> TermCorrection? in
            let hunk = widened(hunk, old: old, new: new)
            let wrong = Array(old[hunk.old]), right = Array(new[hunk.new])
            guard !wrong.isEmpty, !right.isEmpty, wrong.count <= maxWrongWords, right.count <= maxRightWords,
                  right.contains(where: TermTokenizer.looksLikeTerm) else { return nil }
            let wrongKey = wrong.map(\.key).joined(), rightKey = right.map(\.key).joined()
            let distance = editDistance(Array(wrongKey), Array(rightKey))
            guard Double(distance) <= maxDistanceRatio * Double(max(wrongKey.count, rightKey.count)) else { return nil }
            return TermCorrection(
                wrong: wrong.map(\.text).joined(separator: " "),
                right: right.map(\.text).joined(separator: " ")
            )
        }
    }

    private struct Hunk {
        let old: Range<Int>
        let new: Range<Int>
    }

    /// Takes in the neighbours whose case changed with the run: fixing "visuel
    /// studio" into "Visual Studio" replaces one word, but the term is both.
    private static func widened(_ hunk: Hunk, old: [TermToken], new: [TermToken]) -> Hunk {
        var oldRange = hunk.old, newRange = hunk.new
        while oldRange.lowerBound > 0, newRange.lowerBound > 0,
              old[oldRange.lowerBound - 1].key == new[newRange.lowerBound - 1].key,
              old[oldRange.lowerBound - 1].text != new[newRange.lowerBound - 1].text {
            oldRange = (oldRange.lowerBound - 1)..<oldRange.upperBound
            newRange = (newRange.lowerBound - 1)..<newRange.upperBound
        }
        while oldRange.upperBound < old.count, newRange.upperBound < new.count,
              old[oldRange.upperBound].key == new[newRange.upperBound].key,
              old[oldRange.upperBound].text != new[newRange.upperBound].text {
            oldRange = oldRange.lowerBound..<(oldRange.upperBound + 1)
            newRange = newRange.lowerBound..<(newRange.upperBound + 1)
        }
        return Hunk(old: oldRange, new: newRange)
    }

    /// The runs of words between two matches of the longest common subsequence.
    private static func replacedRuns(_ a: [String], _ b: [String], table: [[Int]]) -> [Hunk] {
        var hunks: [Hunk] = []
        var i = 0, j = 0, oldStart = 0, newStart = 0
        func close() {
            if oldStart < i || newStart < j { hunks.append(Hunk(old: oldStart..<i, new: newStart..<j)) }
        }
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                close()
                i += 1
                j += 1
                oldStart = i
                newStart = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = a.count
        j = b.count
        close()
        return hunks
    }

    /// `table[i][j]`: length of the longest common subsequence of `a[i...]` and `b[j...]`.
    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// The names and technical words already written in the field, before the cursor.
nonisolated enum RecurringTerms {
    /// Each term once, in order of appearance. The first word is skipped: the
    /// text is the end of the field, and may start in the middle of a word.
    static func terms(in precedingText: String) -> [String] {
        var seen: Set<String> = []
        return TermTokenizer.tokens(in: precedingText).dropFirst()
            .filter(TermTokenizer.looksLikeTerm)
            .filter { seen.insert($0.key).inserted }
            .map(\.text)
    }
}
