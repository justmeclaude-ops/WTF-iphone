import Foundation

// The thread map: a conversation as the trail of topics it wandered through, with the ones
// that were dropped part-way ("left hanging") marked, and what you were in the middle of saying.

public struct TopicThread: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// What's being talked about now.
        case current
        /// Came to a natural end.
        case finished
        /// Dropped part-way: the one you'll want back.
        case hanging
        /// Was left hanging, then picked up again later (a later thread carries on with it).
        case resumed
    }

    public var id: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var status: Status
    /// When left hanging: what you were in the middle of saying.
    public var leftAt: String?

    public init(id: UUID = UUID(), title: String, start: Date, end: Date, status: Status = .current, leftAt: String? = nil) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.status = status; self.leftAt = leftAt
    }
}

/// What the AI made of the newest lines.
public struct TopicChange: Sendable {
    public var sameTopic: Bool
    public var newTopic: String
    public var previousFinished: Bool
    public var leftAt: String
    /// 1-based number of an earlier topic the new lines go back to, or 0.
    public var returnsTo: Int
    public init(sameTopic: Bool, newTopic: String, previousFinished: Bool, leftAt: String, returnsTo: Int) {
        self.sameTopic = sameTopic; self.newTopic = newTopic; self.previousFinished = previousFinished
        self.leftAt = leftAt; self.returnsTo = returnsTo
    }
}

public enum Threads {
    /// The topics before the current one, as numbered in the prompt.
    public static func earlier(_ threads: [TopicThread]) -> [TopicThread] {
        threads.last?.status == .current ? Array(threads.dropLast()) : threads
    }

    /// Applies what the AI decided about lines heard between [from] and [to].
    public static func apply(_ change: TopicChange, to threads: [TopicThread], from: Date, to: Date) -> [TopicThread] {
        var out = threads
        let title = clean(change.newTopic)
        guard let lastIndex = out.indices.last, out[lastIndex].status == .current else {
            out.append(TopicThread(title: title ?? "Chatting", start: from, end: to))
            return out
        }
        let previous = earlier(out)
        let back = previous.indices.contains(change.returnsTo - 1) ? previous[change.returnsTo - 1] : nil
        let newTitle = back?.title ?? title
        // Still on it, or "new" under the same name.
        if (change.sameTopic && back == nil) || newTitle == nil || newTitle!.caseInsensitiveCompare(out[lastIndex].title) == .orderedSame {
            out[lastIndex].end = max(out[lastIndex].end, to)
            return out
        }
        let leftAt = change.leftAt.trimmingCharacters(in: .whitespacesAndNewlines)
        out[lastIndex].status = change.previousFinished || leftAt.isEmpty ? .finished : .hanging
        out[lastIndex].leftAt = out[lastIndex].status == .hanging ? leftAt : nil
        if let back, let i = out.firstIndex(where: { $0.id == back.id }), out[i].status == .hanging { out[i].status = .resumed }
        out.append(TopicThread(title: newTitle!, start: from, end: to))
        return out
    }

    /// The conversation's over: whatever was being talked about ended with it.
    public static func close(_ threads: [TopicThread]) -> [TopicThread] {
        threads.map { var t = $0; if t.status == .current { t.status = .finished }; return t }
    }

    /// The topics still left hanging, newest first.
    public static func hanging(_ threads: [TopicThread]) -> [TopicThread] {
        threads.filter { $0.status == .hanging }.reversed()
    }

    /// "Mum's birthday present" from whatever the model wrote: no quotes or full stop, at most 6 words.
    public static func clean(_ title: String) -> String? {
        var t = title.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'\u{201C}\u{201D}.:"))
        t = t.split(separator: " ").prefix(6).joined(separator: " ")
        guard !t.isEmpty, t.lowercased() != "none", t.lowercased() != "n/a" else { return nil }
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    /// For the AI: which topic the newest lines belong to.
    public static func prompt(_ threads: [TopicThread], recent: String, new: String) -> String {
        let previous = earlier(threads)
        var p = ""
        if !previous.isEmpty {
            p += "Earlier topics in this conversation:\n"
            for (i, t) in previous.enumerated() {
                p += "\(i + 1). \(t.title)\(t.status == .hanging ? " (dropped part-way)" : "")\n"
            }
            p += "\n"
        }
        if let current = threads.last, current.status == .current {
            p += "Current topic: \(current.title)\n"
            if !recent.isEmpty { p += "Just before:\n\(Prompts.tail(TranscriptFormat.compact(recent), budget: 500))\n" }
            p += "\nNew lines:\n\(Prompts.tail(TranscriptFormat.compact(new), budget: 900))\n\n"
            p += """
                Do the new lines carry on the current topic? If they move on, name the new topic in 2 to 5 words, \
                say whether "\(current.title)" came to a natural end or was dropped part-way, and if it was dropped, \
                what I was in the middle of saying, in under 15 words, starting with "you were". If the new lines go \
                back to one of the earlier topics, give its number.
                """
        } else {
            p += "Lines from a conversation:\n\(Prompts.tail(TranscriptFormat.compact(new), budget: 900))\n\n"
            p += "Name what these lines are about in 2 to 5 words. This is a new topic."
        }
        return p
    }
}

/// Words the recogniser should expect: the people you've named, the shops and the things on
/// your list. (Without them "Asda" comes out as "aspen".)
public enum Vocabulary {
    public static let shops = [
        "Asda", "Tesco", "Sainsbury's", "Aldi", "Lidl", "Morrisons", "Waitrose", "Co-op", "Iceland", "M&S",
        "Boots", "Superdrug", "Argos", "Greggs", "Primark", "B&Q", "Wickes", "Screwfix", "Toolstation", "Currys",
        "Halfords", "B&M", "Home Bargains", "Poundland", "The Range", "Dunelm", "IKEA", "Costa", "Pret", "Nando's",
    ]

    /// At most [limit] words: people first, then list items, then shops.
    public static func words(people: [String], items: [String], limit: Int = 100) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ w: String) {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t != Labels.me, seen.insert(t.lowercased()).inserted, out.count < limit else { return }
            out.append(t)
        }
        people.forEach(add)
        // Names and places in list items: the capitalised words after the first.
        for item in items {
            for w in item.split(separator: " ").dropFirst() where w.first?.isUppercase == true {
                add(String(w).trimmingCharacters(in: .punctuationCharacters))
            }
        }
        shops.forEach(add)
        return out
    }
}
