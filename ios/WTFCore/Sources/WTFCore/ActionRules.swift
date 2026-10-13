import Foundation

public enum ActionType: String, Codable, Sendable { case event = "EVENT", buy = "BUY", todo = "TODO" }

/// Something worth acting on, pulled out of a conversation.
public struct ExtractedAction: Equatable, Sendable {
    public var type: ActionType
    public var title: String
    /// The date/time words as spoken (appointments only).
    public var whenText: String?
    public var place: String?
    /// [whenText] resolved against when the conversation happened; nil if unclear.
    public var resolved: WhenResult?

    public init(type: ActionType, title: String, whenText: String? = nil, place: String? = nil, resolved: WhenResult? = nil) {
        self.type = type; self.title = title; self.whenText = whenText; self.place = place; self.resolved = resolved
    }
}

/// Finds appointments, shopping and to-dos in transcript lines ("[11:40:02] You: …"). Cheap cues
/// pick the lines worth reading; precise rules find items with no AI at all; the AI's own
/// findings are merged in when the phone has one. (Ported from the Android app.)
public enum ActionRules {
    static let eventCues = Rx(
        #"\b(appointment|meeting|dentist|doctor'?s?|gp|hospital|vet|interview|booked|book (it|a|in)|reservation|"# +
        #"party|wedding|birthday|dinner|lunch|drinks|deadline|flight|train|match|gig|"# +
        #"monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|next week|weekend|"# +
        #"\d{1,2}(:\d\d)?\s*(am|pm|a\.m\.|p\.m\.)|o'clock|half (past )?(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d)|"# +
        #"the \d{1,2}(st|nd|rd|th))\b"#)
    static let buyCues = Rx(
        #"\b(buy|bought|get (some|more|a|an|the)|pick up|picking up|grab|need (some|more)|run(ning)? out|ran out|"# +
        #"out of|shopping|groceries|supermarket|tesco|sainsbury'?s|asda|aldi|lidl|we'?ve got no|there'?s no)\b"#)
    static let todoCues = Rx(
        #"\b(i'?ll|i will|i need to|i have to|i must|i've got to|i gotta|remind me|don'?t forget|"# +
        #"remember to|i should|i'm going to|i promised)\b"#)

    /// Lines that might hold something to act on, each with the line after it for context.
    public static func candidateLines(_ transcript: String) -> [String] {
        let lines = transcript.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var keep = Set<Int>()
        for (i, l) in lines.enumerated() {
            let text = l.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            if eventCues.test(text) || buyCues.test(text) || todoCues.test(text) {
                keep.insert(i)
                if i + 1 < lines.count { keep.insert(i + 1) }
            }
        }
        return keep.sorted().map { lines[$0] }
    }

    static let item = #"([a-z][a-z'-]*(?:\s+[a-z][a-z'-]*){0,2}(?:(?:\s*,\s*|\s+and\s+)[a-z][a-z'-]*(?:\s+[a-z][a-z'-]*){0,2})*)"#
    static let itemEnd = #"(?=\s+(?:for|on|from|at|when|tomorrow|today|tonight|later|please|too|as well|again|on the way|if|because|so)\b|[.,!?]|$)"#
    static let buyRules = [
        Rx(#"\b(?:pick up|picking up|buy|grab|get|order)\s+(?:some|more|a few|a couple of|a|an|the|new)\s+"# + item + itemEnd),
        Rx(#"\b(?:buy|grab|pick up)\s+"# + item + itemEnd),
        Rx(#"\b(?:run(?:ning)? out of|ran out of|out of|we've got no|we have no|there's no)\s+"# + item + itemEnd),
        Rx(#"\bneed (?:some|more)\s+"# + item + itemEnd),
    ]
    static let notItems: Set<String> = [
        "it", "that", "this", "them", "those", "these", "one", "ones", "something", "anything", "time", "way", "back",
        "rid", "sorted", "ready", "going", "home", "there", "here", "him", "her", "you", "me", "us", "idea", "touch",
        "bit", "lot", "chance", "work", "bed", "sleep", "money", "breath", "luck", "date", "room", "link", "place",
        // Things you "get" that aren't shopping: "get a good answer", "get a look at it".
        "answer", "answers", "question", "look", "feel", "feeling", "sense", "job", "word", "view", "result", "reply",
        "response", "point", "problem", "picture", "grip", "hold", "kick", "laugh", "glimpse", "shot", "start", "break",
        "rest", "deal", "go", "say", "clue", "grade", "score", "good", "great", "bad", "better", "best", "worse", "worst",
    ]
    static let todoRule = Rx(
        #"\b(?:i'?ll|i will|i need to|i have to|i've got to|i must|remind me to|don'?t forget to|remember to|i'm going to|i promised to)\s+(.{4,80}?)\s*(?:[.!?]|$)"#)
    /// "get it sorted", "do that", "sort this out": no idea what the task actually is.
    static let vagueTask = Rx(#"^\w+\s+(it|that|this|them|one)(\s+\w+)?$"#)
    static let eventNoun = Rx(
        #"\b(?:([a-z]+'s) )?(appointment|dentist|dental|doctor|gp|vet|interview|meeting|party|birthday|wedding|anniversary|"# +
        #"dinner|lunch|drinks|deadline|flight|match|gig|check-up|checkup|game night|parents' evening)\b"#)
    static let agreed = Rx(#"\b(works|perfect|booked|see you|confirmed|that's fine|sounds good|great|lovely|yes|yeah)\b"#)
    static let bogusEventTitle = Rx(#"^(discuss|discussing|talk|talking|chat|conversation|meeting for .* link)"#)
    static let vagueWhen = Rx(#"any ?time|unspecified|not (specified|said|given)|unknown|^\s*(nothing|none|n/?a|later|soon|sometime|some time|eventually)\s*$"#)
    static let clauses = Rx(#"[.?!;]\s+|,?\s+and then\s+|,\s+then\s+"#)
    /// Eating out isn't shopping: "grab some Chinese food from a restaurant".
    static let eatingOut = Rx(#"\b(restaurant|takeaway|take-away|takeout|chippy|caf[eé]|pub|bar|drive-?thru|deliveroo|just eat|uber eats|order in|eat out|eating out)\b"#)
    static let buyTodo = Rx(
        #"^(?:buy|get|grab|pick up|pick-up|order)\s+(?:some\s+|more\s+|a\s+|an\s+|the\s+|new\s+)?(.+?)"# +
        #"(?:\s+(?:tomorrow|today|tonight|later|on the way.*|from .*|at the .*|for (?:the|a) .*|when .*))?$"#)
    static let notShopping = Rx(#"\b(card|present|gift|tickets?|appointment|room|table)\b"#)

    static func text(_ line: String) -> String {
        let afterTime = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ")
        return afterTime.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
    }
    static func speaker(_ line: String) -> String {
        let afterTime = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ")
        return afterTime.components(separatedBy: ":").first ?? ""
    }
    static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "milk and bread" / "eggs, butter and jam" -> separate items.
    static func splitItems(_ s: String) -> [String] {
        Rx(#"\s*,\s*|\s+and\s+|\s*&\s*"#).split(s).map { piece in
            var t = piece.trimmingCharacters(in: .whitespaces)
            for p in ["some ", "more "] where t.hasPrefix(p) { t.removeFirst(p.count) }
            return t
        }.filter { !$0.isEmpty }
    }

    /// Actions found by rules alone. [title] names an agreed plan with no clear noun.
    /// [youOnly] keeps to-dos to lines by "You" (the Android app knows voices); with no voices
    /// to go on, every line counts.
    public static func ruleActions(_ lines: [String], conversationStart: Date, title: String?, calendar: Calendar = .current, youOnly: Bool = true) -> [ExtractedAction] {
        var out: [ExtractedAction] = []
        for line in lines {
            let t = text(line)
            // Clause by clause, so "go to the pub and then get some milk" still finds the milk.
            for clause in clauses.split(t) where !eatingOut.test(clause) {
                for rule in buyRules {
                    for m in rule.all(clause) {
                        for it in splitItems(m[1]) where it.count >= 2 && it.count <= 40 &&
                            !it.split(separator: " ").contains(where: { notItems.contains($0.lowercased()) }) {
                            out.append(ExtractedAction(type: .buy, title: capitalised(it)))
                        }
                    }
                }
            }
            if !youOnly || speaker(line) == "You", let m = todoRule.first(t) {
                var task = m[1].trimmingCharacters(in: .whitespaces)
                for p in ["also ", "just "] where task.hasPrefix(p) { task.removeFirst(p.count) }
                // "Tom, I'll send you that link" -> "send Tom that link"
                if let v = Rx(#"^([A-Z][a-z]+),"#, caseSensitive: true).first(t) {
                    task = Rx(#"\byou\b"#, caseSensitive: true).replace(task, with: v[1])
                }
                if !buyRules.contains(where: { $0.test("I'll " + task) }) && !vagueTask.test(task) {
                    out.append(ExtractedAction(type: .todo, title: capitalised(task)))
                }
            }
            if let resolved = WhenParser.parse(t, reference: conversationStart, calendar: calendar),
               resolved.hour != nil || eventNoun.test(t) {
                if let noun = eventNoun.first(t) {
                    let name = (noun[1] + " " + noun[2]).trimmingCharacters(in: .whitespaces)
                    out.append(ExtractedAction(type: .event, title: capitalised(name), whenText: t, resolved: resolved))
                } else if let title, agreed.test(t) {
                    out.append(ExtractedAction(type: .event, title: title, whenText: t, resolved: resolved))
                }
            }
        }
        return out
    }

    /// The AI's findings, tidied: shopping filed as a task becomes shopping; lists split up.
    public static func fromModel(buy: [String], todo: [String], events: [(what: String, when: String?, place: String?)],
                                 conversationStart: Date, calendar: Calendar = .current) -> [ExtractedAction] {
        var out: [ExtractedAction] = []
        for b in buy { for it in splitItems(b) { out.append(ExtractedAction(type: .buy, title: String(capitalised(it).prefix(60)))) } }
        for t in todo {
            let task = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty else { continue }
            if let m = buyTodo.whole(task), !notShopping.test(task) {
                for it in splitItems(m[1]) { out.append(ExtractedAction(type: .buy, title: String(capitalised(it).prefix(60)))) }
            } else {
                out.append(ExtractedAction(type: .todo, title: String(capitalised(task).prefix(100))))
            }
        }
        for e in events where !e.what.isEmpty && !bogusEventTitle.test(e.what.lowercased()) {
            // Only real plans: a day or a time actually said ("Thursday at 3"), not "later" or "nothing".
            guard let whenText = e.when.flatMap({ $0.isEmpty ? nil : $0 }), !vagueWhen.test(whenText.lowercased()),
                  let resolved = WhenParser.parse(whenText, reference: conversationStart, calendar: calendar) else { continue }
            out.append(ExtractedAction(
                type: .event, title: String(capitalised(e.what).prefix(80)), whenText: whenText,
                place: e.place.flatMap { $0.isEmpty ? nil : $0 }, resolved: resolved))
        }
        return out
    }

    static let stop: Set<String> = ["the", "a", "an", "to", "for", "of", "and", "some", "my", "your", "with", "on", "at", "by", "tonight", "tomorrow", "today"]
    static func words(_ s: String) -> Set<String> {
        Set(Rx(#"[a-z0-9']+"#).all(s.lowercased()).map { w in
            var x = w[0]
            if x.hasSuffix("s") { x.removeLast() }
            return x
        }.filter { !stop.contains($0) })
    }

    /// Mostly the same words: "Milk" and "some milk", "Send Tom the link" and "send the link to Tom".
    public static func similar(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.5
    }

    /// The AI's findings plus the rules', de-duplicated (the AI's wording wins).
    public static func merge(_ model: [ExtractedAction], _ rules: [ExtractedAction]) -> [ExtractedAction] {
        var kept = model.filter { a in
            !(a.type == .event && (bogusEventTitle.test(a.title) || (a.whenText.map(vagueWhen.test) ?? false)))
        }
        for r in rules {
            let dup = kept.contains { k in
                if k.type == .event && r.type == .event {
                    let sameDay = k.resolved.map { [$0.year, $0.month, $0.day] } == r.resolved.map { [$0.year, $0.month, $0.day] } && k.resolved != nil
                    return sameDay || similar(k.title, r.title)
                }
                return (k.type == r.type && similar(k.title, r.title)) || (r.type == .buy && k.type == .todo && similar(k.title, r.title))
            }
            if !dup { kept.append(r) }
        }
        var seen = Set<String>()
        return kept.filter { seen.insert($0.type.rawValue + "|" + $0.title.lowercased()).inserted }
    }
}
