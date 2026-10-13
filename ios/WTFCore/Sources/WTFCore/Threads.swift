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

/// What the AI made of the newest lines: the topics they moved through, in order.
public struct TopicChange: Sendable {
    public var topics: [String]
    /// For each topic but the last: dropped part-way (true) or finished (false).
    public var dropped: [Bool]
    /// What you were in the middle of saying when a topic was dropped.
    public var leftAt: String
    public init(topics: [String], dropped: [Bool] = [], leftAt: String = "") {
        self.topics = topics; self.dropped = dropped; self.leftAt = leftAt
    }
}

public enum Threads {
    /// The topics before the current one, as numbered in the prompt.
    public static func earlier(_ threads: [TopicThread]) -> [TopicThread] {
        threads.last?.status == .current ? Array(threads.dropLast()) : threads
    }

    /// Applies what the AI made of lines heard between [from] and [to]. Several topics in one
    /// stretch share its time evenly (the recording doesn't say exactly where each began).
    public static func apply(_ change: TopicChange, to threads: [TopicThread], from: Date, to: Date) -> [TopicThread] {
        var titles: [String] = []
        for t in change.topics.compactMap(clean) where titles.last.map({ !same($0, t) }) ?? true { titles.append(t) }
        var out = threads
        let currentIndex = out.indices.last.flatMap { out[$0].status == .current ? $0 : nil }
        guard !titles.isEmpty else {
            if let i = currentIndex { out[i].end = max(out[i].end, to) }
            return out
        }
        let span = max(0, to.timeIntervalSince(from)) / Double(titles.count)
        let leftAt = change.leftAt.trimmingCharacters(in: .whitespacesAndNewlines)
        // The last dropped topic in this stretch is the one [leftAt] is about.
        let lastDropped = titles.indices.dropLast().last { change.dropped.indices.contains($0) && change.dropped[$0] }
        for (k, title) in titles.enumerated() {
            let segFrom = from.addingTimeInterval(span * Double(k)), segTo = from.addingTimeInterval(span * Double(k + 1))
            if let i = out.indices.last, out[i].status == .current {
                if same(out[i].title, title) {
                    out[i].end = max(out[i].end, segTo)
                    continue
                }
                // Moving on: how did the one before end? (For one carried over from earlier, we can't tell: finished.)
                let droppedHere = k > 0 && change.dropped.indices.contains(k - 1) && change.dropped[k - 1]
                out[i].status = droppedHere ? .hanging : .finished
                out[i].leftAt = droppedHere && k - 1 == lastDropped && !leftAt.isEmpty ? leftAt : nil
                if out[i].status == .hanging && out[i].leftAt == nil { out[i].leftAt = "" }
            }
            // Back to something from before: that one's picked up again, under its own name.
            var name = title
            if let j = out.lastIndex(where: { same($0.title, title) }) {
                name = out[j].title
                if out[j].status == .hanging { out[j].status = .resumed }
            }
            out.append(TopicThread(title: name, start: segFrom, end: segTo))
        }
        return out
    }

    /// The same topic, give or take capitals and "the".
    static func same(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().split(separator: " ").filter { !["the", "a", "an", "about"].contains($0) }.joined(separator: " ")
        }
        return key(a) == key(b)
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
        let ask = """
            List the topics these lines move through, in order (1 to 4), each named in 2 to 5 words by what is \
            actually being talked about. Count quick tangents as topics too: that's what this is for. For each topic \
            except the last, say whether it was dropped part-way, unfinished, or came to an end. If one was dropped, \
            say what I was in the middle of saying about it, starting with "you were".
            """
        if let current = threads.last, current.status == .current {
            p += "Current topic: \(current.title) (if the new lines carry on with it, list it first under that name)\n"
            if !recent.isEmpty { p += "Just before:\n\(Prompts.tail(TranscriptFormat.compact(recent), budget: 500))\n" }
            p += "\nNew lines:\n\(Prompts.tail(TranscriptFormat.compact(new), budget: 900))\n\n" + ask
        } else {
            p += "Lines from a conversation:\n\(Prompts.tail(TranscriptFormat.compact(new), budget: 900))\n\n" + ask
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
