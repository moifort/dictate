import Foundation

/// The alignments the app runs on words and characters: the longest common
/// subsequence and the edit distance, once for every caller.
nonisolated enum SequenceAlignment {
    /// `table[i][j]`: length of the longest common subsequence of `a[i...]` and `b[j...]`.
    static func commonSubsequenceTable<Element: Equatable>(_ a: [Element], _ b: [Element]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }

    /// Index pairs of the elements both sequences share, in order.
    static func commonSubsequence<Element: Equatable>(_ a: [Element], _ b: [Element]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let table = commonSubsequenceTable(a, b)
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Levenshtein distance, every insertion, deletion or substitution costing one.
    static func editDistance<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
