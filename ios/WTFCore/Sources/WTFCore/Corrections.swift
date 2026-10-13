import Foundation

/// Fixing what the recogniser misheard, from context ("bucked the back room" → "booked the back
/// room", "half free" → "half three"). The AI proposes a corrected line; it's only taken if it
/// changes a few words and leaves the rest exactly as said, so it can't rewrite what you said.
public enum Corrections {
    /// At least this share of the words must be untouched, in order.
    static let keep = 0.8

    /// The lines' words for the AI, numbered: "1. Right, so we need to sort Mum's birthday."
    public static func prompt(_ lines: [String]) -> String {
        let numbered = lines.enumerated().map { "\($0.offset + 1). \(text(of: $0.element))" }.joined(separator: "\n")
        return """
            These lines were written down by speech recognition, which sometimes mishears a word: "bucked the back \
            room" for "booked the back room", "half free" for "half three", "scar" for "scarf", "double a" for "AA". \
            Using the context, fix only words that were clearly misheard. Keep everything else exactly as it is: \
            the same words in the same order, no rephrasing, nothing added or left out. Give back every line, \
            numbered as here, even if it needs no change.

            \(numbered)
            """
    }

    /// [original] lines with the AI's [corrected] texts put in where they pass the checks.
    public static func apply(_ corrected: [String], to original: [String]) -> [String] {
        original.enumerated().map { i, line in
            guard i < corrected.count else { return line }
            let fixed = Rx(#"^\s*\d+[.)]\s*"#).replace(corrected[i], with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard accept(fixed, for: text(of: line)) else { return line }
            return prefix(of: line) + fixed
        }
    }

    /// A small fix, not a rewrite: most words the same, in the same order, about the same length.
    public static func accept(_ fixed: String, for original: String) -> Bool {
        let a = words(original), b = words(fixed)
        guard !b.isEmpty, a != b else { return false }
        guard abs(a.count - b.count) <= max(2, a.count / 10) else { return false }
        return Double(commonInOrder(a, b)) / Double(max(a.count, b.count)) >= keep
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// The longest run of words both share, in order (LCS).
    static func commonInOrder(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// "[13:16:00] Speaker 1: " and the words after it.
    static func prefix(of line: String) -> String {
        guard let g = TranscriptFormat.turn.whole(line) else { return "" }
        return String(line.dropLast(g[2].count))
    }

    static func text(of line: String) -> String {
        TranscriptFormat.turn.whole(line)?[2] ?? line
    }
}
