import Foundation

/// What a question is after: decides which transcript the AI reads.
public enum RecallIntent: Equatable, Sendable { case latest, digest, commitments, focused }

/// Builds prompts for Apple's on-device model, whose context is small (4,096 tokens), so it's
/// given only what the question needs. (A short version of the Android app's LocalRecall.)
public enum Prompts {
    static let commitment = Rx(#"promis|said i'?d|i said i would|to-?do|commit|agreed to|supposed to|\bowe\b|need to do|have to do"#)
    static let digest = Rx(#"summar|recap|my day|overview|what did i do|what have i (done|been doing)|everything"#)
    static let latest = Rx(#"\bjust\b|a (minute|moment|sec|second)s? ago|right now|where was i|lost (my|the) (train|thread)|interrupted|on about|what was i (saying|talking)"#)
    static let timeWords = Rx(#"\b(yesterday|this morning|last night|earlier|today|afternoon|evening|lunch|hours? ago)\b"#)

    public static func intent(_ question: String) -> RecallIntent {
        let q = question.lowercased()
        if commitment.test(q) { return .commitments }
        if digest.test(q) { return .digest }
        if latest.test(q) && !timeWords.test(q) { return .latest }
        return .focused
    }

    /// Roughly 4 characters a token in English.
    public static func tokens(_ s: String) -> Int { s.count / 4 + 1 }

    /// The last lines of [transcript] that fit in [budget] tokens, oldest first.
    public static func tail(_ transcript: String, budget: Int) -> String {
        var kept: [Substring] = []
        var used = 0
        for line in transcript.split(separator: "\n").reversed() {
            let t = tokens(String(line)) + 1
            if used + t > budget { break }
            kept.insert(line, at: 0)
            used += t
        }
        let cut = kept.count < transcript.split(separator: "\n").count
        return (cut ? "(\u{2026}earlier part left out\u{2026})\n" : "") + kept.joined(separator: "\n")
    }

    public static let instructions = """
        You are WTF, a memory aid for someone who goes off on tangents and loses their train of thought. \
        Their phone records their day and transcribes it. In transcripts, lines marked "You" are theirs; other \
        voices are numbered ("Speaker 2") or named. Answer briefly and plainly, talk to them as "you", \
        and use only the notes you're given; if they don't answer the question, say so.
        """

    /// "What was I just on about?": only the last few minutes of the latest conversation.
    public static func latest(question: String, transcript: String, topic: String?, now: Date) -> String {
        """
        The most recent conversation\(topic.map { " (topic: \($0))" } ?? ""), in order, oldest first; the last line is the most recent:
        \(tail(TranscriptFormat.compact(transcript), budget: 900))

        It is now \(clock(now)). In 2 or 3 sentences, tell me what I was just talking about. If my last words trail off \
        unfinished, say what I was in the middle of saying. Only say I was interrupted if someone else spoke after me.
        My question: \(question)
        """
    }

    /// The same, for reading aloud in your ear: one or two short sentences, no lists.
    public static func spoken(transcript: String, topic: String?, leftAt: String?, now: Date) -> String {
        """
        The most recent conversation\(topic.map { " (topic: \($0))" } ?? ""), oldest first; the last line is the most recent:
        \(tail(TranscriptFormat.compact(transcript), budget: 700))
        \(leftAt.map { "\nEarlier, I dropped a topic part-way: \($0)\n" } ?? "")
        It is now \(clock(now)). In one or two short sentences that will be read aloud to me, say what I was just \
        talking about and, if I trailed off, what I was in the middle of saying. No lists, no quotation marks.
        """
    }

    /// "Where was I with ...?": one topic from the trail, and the talk around it.
    public static func thread(_ title: String, leftAt: String?, lines: String) -> String {
        """
        In a conversation, this topic came up: \(title). What was said around then, oldest first:
        \(tail(TranscriptFormat.compact(lines), budget: 1_200))
        \(leftAt.flatMap { $0.isEmpty ? nil : "\nIt seems I dropped it part-way: \($0)\n" } ?? "")
        In one or two sentences, remind me where I'd got to with \(title), and if I trailed off, what I was about \
        to say. Only use what's above; if it barely comes up, say so.
        """
    }

    /// The sentences in [lines] that mention [topic]'s words, for when there's no AI.
    public static func sentences(about topic: String, in lines: String, limit: Int = 3) -> [String] {
        let keys = keywords(topic).map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        guard !keys.isEmpty else { return [] }
        let text = TranscriptFormat.compact(lines).replacingOccurrences(of: "\n", with: " ")
        return Rx(#"(?<=[.?!])\s+"#).split(text).filter { s in
            let l = s.lowercased()
            return keys.contains { l.contains($0) }
        }.prefix(limit).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Any other question: titles and summaries of the day, plus the best-matching transcript.
    public static func focused(question: String, notes: [(label: String, title: String?, summary: String?)], best: (label: String, transcript: String)?, now: Date) -> String {
        var body = "Conversations recorded on my phone:\n"
        for n in notes.prefix(12) {
            body += "- \(n.label): \(n.title ?? "untitled")" + (n.summary.map { "\n  " + $0.replacingOccurrences(of: "\n", with: "\n  ") } ?? "") + "\n"
        }
        if let best { body += "\nTranscript of \(best.label):\n" + tail(TranscriptFormat.compact(best.transcript), budget: 1_600) + "\n" }
        return body + "\nIt is now \(clock(now)). Answer my question in 2 to 4 short sentences, saying which conversation (its time) you mean.\nMy question: \(question)"
    }

    /// Keywords for finding the right conversation.
    public static func keywords(_ question: String) -> [String] {
        let stop: Set<String> = ["the", "and", "was", "were", "what", "when", "where", "who", "why", "how", "did", "does", "about", "with",
                                 "that", "this", "they", "them", "said", "say", "tell", "remind", "remember", "earlier", "today",
                                 "yesterday", "just", "you", "your", "have", "had", "has", "been", "talking", "saying", "conversation"]
        var seen = Set<String>()
        return Rx(#"[A-Za-z][A-Za-z']+"#).all(question).map { $0[0].lowercased() }
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE HH:mm"
        return f.string(from: d)
    }

    /// For summarising: the conversation as compact as it goes, cut to fit.
    public static func summary(transcript: String) -> String {
        "Summarise this conversation from my day. Say what was decided and what was only suggested or still needs doing " +
            "(a plan that has to be confirmed isn't booked). Keep each detail with what it was about: don't connect things " +
            "that weren't connected (if batteries are for the remote, they aren't for a present).\n\n" + tail(TranscriptFormat.compact(transcript), budget: 2_400)
    }

    /// For finding things to act on.
    public static func actions(lines: [String], conversationStart: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        return """
            Lines from a conversation recorded on \(f.string(from: conversationStart)). Find appointments (with when they are, \
            in the words used), things to buy (one per item), and things the speaker said they would do. Be strict: an \
            appointment needs a day or a time actually said, and say whether it was actually booked or only suggested; if it \
            still has to be booked or confirmed, add that as something to do; things to buy are shopping (groceries, household things), not \
            meals out or takeaways; a film, a show or a topic mentioned in passing is none of these. Only what was actually \
            said; leave a list empty if there's nothing for it.

            \(lines.joined(separator: "\n"))
            """
    }
}
