import Foundation

// Helping the small on-device model understand more than it can read at once: a running memory
// of each conversation, facts that last across days, names worked out from how people are
// addressed, appointments checked against the calendar, and finding what's relevant to a question.

/// What's been established in a conversation so far, kept up to date as it goes, so recaps,
/// lists and answers see the whole conversation and not only its last few minutes.
public struct ConversationMemory: Codable, Equatable, Sendable {
    /// Who's there and who they seem to be: "Speaker 2: probably Sarah, organising the party".
    public var people: [String]
    /// Agreed or settled.
    public var decided: [String]
    /// Ideas and plans put forward but not settled.
    public var suggested: [String]
    /// Things someone said they'd do: "You: ring the garage to confirm the MOT".
    public var todo: [String]
    /// Dates, times, places, names and numbers mentioned.
    public var facts: [String]
    /// Questions left unanswered, or a topic dropped part-way.
    public var open: [String]

    public init(people: [String] = [], decided: [String] = [], suggested: [String] = [], todo: [String] = [], facts: [String] = [], open: [String] = []) {
        self.people = people; self.decided = decided; self.suggested = suggested; self.todo = todo; self.facts = facts; self.open = open
    }

    public static let empty = ConversationMemory()
    public var isEmpty: Bool { [people, decided, suggested, todo, facts, open].allSatisfy(\.isEmpty) }

    /// Tidied: trimmed, no blanks or repeats, each list kept short, each note under 20 words.
    public func cleaned(perList: Int = 8) -> ConversationMemory {
        func tidy(_ list: [String]) -> [String] {
            var seen: [String] = []
            for raw in list {
                var t = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2022}*")))
                t = t.split(separator: " ").prefix(20).joined(separator: " ")
                let l = t.lowercased()
                guard !t.isEmpty, !["none", "n/a", "nothing", "unknown"].contains(l),
                      !seen.contains(where: { ActionRules.similar($0, t) && abs($0.count - t.count) < 12 }) else { continue }
                seen.append(t)
            }
            return Array(seen.suffix(perList))
        }
        return ConversationMemory(people: tidy(people), decided: tidy(decided), suggested: tidy(suggested), todo: tidy(todo), facts: tidy(facts), open: tidy(open))
    }

    /// For a prompt: only the lists with something in them.
    public func text() -> String {
        let parts: [(String, [String])] = [
            ("Who's there", people), ("Decided", decided), ("Suggested, not settled", suggested),
            ("Said they'd do", todo), ("Details", facts), ("Left open", open),
        ]
        return parts.filter { !$0.1.isEmpty }.map { title, items in
            title + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}

extension Prompts {
    /// Bringing a conversation's memory up to date with its newest lines.
    public static func memory(_ before: ConversationMemory, new lines: String) -> String {
        """
        Notes so far on a conversation recorded on my phone (lines marked "You" are mine):
        \(before.isEmpty ? "(none yet)" : before.text())

        New lines:
        \(tail(TranscriptFormat.compact(lines), budget: 1_100))

        Update the notes with the new lines and give them back in full: keep what's still true, add what's \
        new, move a suggestion to decided only if it was agreed, and drop anything that turned out wrong. Keep \
        each detail with what it was about. Short notes, only what was actually said.
        """
    }

    /// A conversation's memory and the facts known from other days, for the top of a prompt.
    public static func background(memory: ConversationMemory?, facts: [String]) -> String {
        var out = ""
        if let memory, !memory.isEmpty { out += "Notes on this conversation so far:\n" + memory.text() + "\n\n" }
        if !facts.isEmpty { out += "Things I know from other days:\n" + facts.map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
        return out
    }
}

/// Facts worth keeping beyond the day they were said ("Mum's birthday is 2 November"): kept in
/// a list you can see and edit, and given to the AI when they're relevant.
public enum KnownFacts {
    /// The facts that share the most words with [text], at most [limit], best first.
    public static func relevant(_ facts: [String], to text: String, limit: Int = 6) -> [String] {
        let want = ActionRules.words(text)
        guard !want.isEmpty else { return [] }
        return facts.map { ($0, ActionRules.words($0).intersection(want).count) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }

    /// The new facts that aren't already known (or near enough).
    public static func fresh(_ found: [String], known: [String]) -> [String] {
        var out: [String] = []
        for raw in found {
            let f = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-\u{2022}*")))
            let words = f.split(separator: " ").count
            guard words >= 3, words <= 25, !(known + out).contains(where: { ActionRules.similar($0, f) && ActionRules.overlap($0, f) >= 3 }) else { continue }
            out.append(f.prefix(1).uppercased() + f.dropFirst())
        }
        return out
    }

    /// Names and places in facts (capitalised words after the first), for the recogniser.
    public static func names(in facts: [String]) -> [String] {
        var out: [String] = []
        for f in facts {
            for w in f.split(separator: " ").dropFirst() where w.first?.isUppercase == true {
                let t = w.trimmingCharacters(in: .punctuationCharacters).replacingOccurrences(of: "'s", with: "").replacingOccurrences(of: "\u{2019}s", with: "")
                if t.count >= 3, !out.contains(t) { out.append(t) }
            }
        }
        return out
    }
}

/// Names for unnamed voices from how people are addressed: "Thanks, Sarah." said straight after
/// Speaker 2 spoke, or "What do you think, Tom?" just before Speaker 3 answers.
public enum NameHints {
    public struct Hint: Equatable, Sendable {
        public var label: String
        public var name: String
        public var times: Int
    }

    static let greeting = #"(?:(?i:hi|hey|hiya|hello|thanks|thank you|cheers|oh|right|so|well|yes|yeah|no|okay|ok|sorry|morning|night|bye|ta)[,!]?\s+)?"#
    /// Addressed at the start of a sentence: "Sarah, what do you think?", "Thanks Sarah, that's lovely."
    static let opening = Rx("^" + greeting + #"([A-Z][a-z]{1,15})(?:[,!?.]|\s*$)"#, caseSensitive: true)
    /// Addressed at the end: "Thanks, Sarah.", "What do you reckon, Tom?"
    static let closing = Rx(#",\s+([A-Z][a-z]{1,15})\s*([.!?])?\s*$"#, caseSensitive: true)

    /// - Parameter isName: whether a word is a person's name (on the phone, Apple's name tagger).
    public static func suggest(_ transcript: String, isName: (String) -> Bool) -> [Hint] {
        let turns: [(who: String, text: String)] = transcript.split(separator: "\n").compactMap {
            TranscriptFormat.turn.whole(String($0)).map { ($0[1], $0[2]) }
        }
        let named = Set(turns.map(\.who).filter { Labels.number($0) == nil })
        var counts: [String: [String: Int]] = [:]
        func credit(_ label: String, _ name: String) {
            guard Labels.number(label) != nil, !named.contains(name), isName(name) else { return }
            counts[label, default: [:]][name, default: 0] += 1
        }
        for (i, turn) in turns.enumerated() {
            let previous = turns[..<i].last { $0.who != turn.who }?.who
            let next = turns[(i + 1)...].first { $0.who != turn.who }?.who
            for sentence in Rx(#"(?<=[.?!])\s+"#).split(turn.text) {
                let found = [opening.first(sentence), closing.first(sentence)].compactMap { $0 }
                    .map { $0[1] }.first { isName($0) }
                guard let name = found else { continue }
                // A question goes to whoever answers it; anything else to whoever spoke before.
                let asked = sentence.trimmingCharacters(in: .whitespaces).hasSuffix("?")
                if let who = asked ? (next ?? previous) : (previous ?? next), who != turn.who { credit(who, name) }
            }
        }
        // One name per voice and one voice per name: the best supported.
        var hints: [Hint] = []
        for (label, names) in counts {
            guard let best = names.max(by: { $0.value < $1.value }) else { continue }
            hints.append(Hint(label: label, name: best.key, times: best.value))
        }
        var out: [Hint] = []
        for h in hints.sorted(by: { $0.times > $1.times }) where !out.contains(where: { $0.name == h.name || $0.label == h.label }) {
            out.append(h)
        }
        return out.sorted { $0.label < $1.label }
    }
}

/// Appointments heard, checked against what's already in the calendar.
public enum CalendarCheck {
    public struct Entry: Sendable {
        public var title: String, start: Date, allDay: Bool
        public init(title: String, start: Date, allDay: Bool) { self.title = title; self.start = start; self.allDay = allDay }
    }

    public enum Result: Equatable, Sendable {
        /// The same thing at the same time: no need to suggest it.
        case alreadyThere
        /// The calendar has it at another time: worth knowing.
        case differs(String)
    }

    /// What the calendar says about [title] at [start], if it has it within a fortnight.
    public static func check(title: String, start: Date, allDay: Bool, against entries: [Entry], calendar: Calendar = .current) -> Result? {
        let matches = entries.filter { e in
            abs(e.start.timeIntervalSince(start)) <= 14 * 86_400 && (ActionRules.similar(e.title, title) || ActionRules.overlap(e.title, title) >= 1 && significant(e.title, title))
        }
        guard !matches.isEmpty else { return nil }
        let sameDay = matches.filter { calendar.isDate($0.start, inSameDayAs: start) }
        if sameDay.contains(where: { allDay || $0.allDay || abs($0.start.timeIntervalSince(start)) <= 90 * 60 }) { return .alreadyThere }
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
        if let e = sameDay.first {
            f.dateFormat = "h:mm a"
            return .differs("Your calendar has it at \(f.string(from: e.start).lowercased())")
        }
        let nearest = matches.min { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) }!
        f.dateFormat = nearest.allDay ? "EEEE d MMMM" : "EEEE d MMMM 'at' h:mm a"
        return .differs("Your calendar has it on \(f.string(from: nearest.start).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm"))")
    }

    /// Sharing a word that says what it is ("dentist"), not just "appointment".
    static func significant(_ a: String, _ b: String) -> Bool {
        let generic: Set<String> = ["appointment", "meeting", "call", "event", "booking", "check", "up", "reminder", "day"]
        return !ActionRules.words(a).intersection(ActionRules.words(b)).subtracting(generic).isEmpty
    }
}

/// Picking what to show the AI for a question: the lines that matter, by meaning and by words.
public enum Retrieval {
    /// The best lines, in their original order, each with its neighbours, within [budget] tokens.
    public static func excerpt(_ lines: [String], scores: [Double], budget: Int, neighbours: Int = 1) -> String {
        guard lines.count == scores.count, !lines.isEmpty else { return "" }
        var keep = Set<Int>()
        var used = 0
        for i in lines.indices.filter({ scores[$0] > 0 }).sorted(by: { scores[$0] > scores[$1] }) {
            let around = max(0, i - neighbours)...min(lines.count - 1, i + neighbours)
            let adding = around.filter { !keep.contains($0) }
            let cost = adding.reduce(0) { $0 + Prompts.tokens(lines[$1]) + 1 }
            if used + cost > budget { if used > budget / 2 { break } else { continue } }
            keep.formUnion(adding)
            used += cost
        }
        var out: [String] = []
        var last = -2
        for i in keep.sorted() {
            if i != last + 1 && !out.isEmpty { out.append("(\u{2026})") }
            out.append(lines[i])
            last = i
        }
        return out.joined(separator: "\n")
    }

    /// Word overlap between a question and a line, 0–1: for when there's no meaning to go on.
    public static func wordScore(_ question: String, _ line: String) -> Double {
        let asking: Set<String> = ["what", "what'", "where", "where'", "when", "who", "who'", "why", "how", "which", "did", "doe", "do",
                                   "wa", "were", "is", "i", "you", "we", "about", "say", "said", "talk", "talking", "tell", "me"]
        let q = ActionRules.words(question).subtracting(asking)
        guard !q.isEmpty else { return 0 }
        return Double(q.intersection(ActionRules.words(line)).count) / Double(q.count)
    }
}
