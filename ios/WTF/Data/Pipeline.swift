import Foundation
import SwiftData
import UserNotifications
import WTFCore

/// Turns recorded chunks into transcripts, groups them into conversations, suggests list items
/// as soon as they're heard, and summarises conversations once they've gone quiet. Runs off
/// the main thread with its own SwiftData context.
@ModelActor
actor Pipeline {
    private var gapMinutes: Int { max(1, UserDefaults.standard.integer(forKey: "gapMinutes").nonZero ?? 5) }
    private var keepDays: Int { UserDefaults.standard.integer(forKey: "keepDays").nonZero ?? 7 }

    /// Work runs in two queues, each one job at a time and in order: transcribing (what a question
    /// waits for) and the slower AI work after it (threads, summaries), so a question never waits
    /// behind a summary, and nothing is done twice.
    private var transcribing: Task<Bool, Never>?
    private var thinking: Task<Void, Never>?
    /// New lines whose topic hasn't been worked out yet (it waits until after any question's answered).
    private var toFollow: [(id: UUID, text: String, from: Date, to: Date)] = []

    func addChunk(url: URL, start: Date, end: Date) {
        modelContext.insert(Chunk(start: start, end: end, path: url.path))
        try? modelContext.save()
    }

    /// Transcribes what's waiting, so a question includes the latest words. Summaries can wait.
    @discardableResult
    func catchUp() async -> Bool {
        let before = transcribing
        let job = Task { _ = await before?.value; return await self.transcribePending() }
        transcribing = job
        return await job.value
    }

    private func transcribePending() async -> Bool {
        let pending = (try? modelContext.fetch(FetchDescriptor<Chunk>(
            predicate: #Predicate { $0.status == "pending" }, sortBy: [SortDescriptor(\.start)]))) ?? []
        guard !pending.isEmpty, await SpeechEngine.shared.isReady() else { return true }
        var ok = true
        for (i, chunk) in pending.enumerated() {
            await MainActor.run { AppModel.shared.transcribing = (i, pending.count) }
            guard let path = chunk.path, FileManager.default.fileExists(atPath: path) else {
                chunk.status = "failed"
                continue
            }
            do {
                // The words and the voices at the same time: Apple's recogniser and the speaker models.
                // Every step has a deadline, so one stuck recording can't hold up the rest.
                let url = URL(fileURLWithPath: path)
                let length = max(1, chunk.end.timeIntervalSince(chunk.start))
                let started = Date()
                async let heardVoices = withDeadline(60 + length) { await VoiceEngine.shared.split(url) }
                // Usually the words were heard live already; if not, from the file.
                var words = await withDeadline(4) { await LiveTranscriber.shared.words(from: chunk.start, to: chunk.end) }
                let live = words != nil
                if words == nil {
                    words = await withDeadline(20 + 2 * length) { () -> [SpeakerAlign.Word]? in
                        do { return try await SpeechEngine.shared.words(url) } catch {
                            Log.error("Speech recognition failed on the recording", error)
                            return nil
                        }
                    }
                }
                guard let words else { throw StepTimedOut(what: "transcribing \(Int(length)) s of audio") }
                let split = await heardVoices
                Log.info("Recording \(chunk.start.formatted(date: .omitted, time: .standard)) (\(Int(length)) s): \(words.count) words \(live ? "live" : "from the file"), \(split?.voices.count ?? 0) voices, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                let target = openConversation(for: chunk)
                var voices = target?.voiceprints ?? []
                let utterances = whoSaidWhat(words, split: split, voices: &voices, before: target?.transcript, start: chunk.start)
                let text = TranscriptFormat.lines(utterances)
                if text.isEmpty {
                    chunk.status = "empty"
                } else {
                    let c = attach(chunk, text: text, to: target)
                    if split != nil { c.voiceprints = voices }
                    chunk.status = "done"
                    chunk.conversationID = c.id
                    try? modelContext.save()
                    await suggest(for: c, found: ruleActions(c))
                    toFollow.append((c.id, text, chunk.start, chunk.end))
                }
                chunk.path = nil
                try? FileManager.default.removeItem(atPath: path)
            } catch {
                Log.error("Couldn't transcribe the recording from \(chunk.start.formatted(date: .omitted, time: .standard)) (try \(chunk.attempts + 1) of 5)", error)
                chunk.attempts += 1
                if chunk.attempts >= 5 { chunk.status = "failed" }
                ok = false
            }
            try? modelContext.save()
        }
        await MainActor.run { AppModel.shared.transcribing = nil }
        return ok
    }

    /// Catch up, then summarise conversations that have gone quiet, then tidy away old ones.
    func run() async {
        await refreshVocabulary()
        await catchUp()
        let before = thinking
        let job = Task { await before?.value; await self.think() }
        thinking = job
        await job.value
    }

    /// The slow part: the thread map, summaries of finished conversations, and tidying up.
    private func think() async {
        await followThreads()
        let quietBefore = Date().addingTimeInterval(-Double(gapMinutes) * 60)
        let waiting = (try? modelContext.fetch(FetchDescriptor<Conversation>(
            predicate: #Predicate { $0.summary == nil }))) ?? []
        for c in waiting where c.closed || c.end < quietBefore {
            await summarise(c)
        }
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        try? modelContext.delete(model: Conversation.self, where: #Predicate { $0.end < cutoff })
        try? modelContext.delete(model: Chunk.self, where: #Predicate { $0.end < cutoff })
        try? modelContext.save()
    }

    func latestConversation() -> (transcript: String, start: Date, end: Date, title: String?)? {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first.map { ($0.transcript, $0.start, $0.end, $0.title) }
    }

    /// Counts for the diagnostics report (no content).
    func health() -> String {
        func count<T: PersistentModel>(_ d: FetchDescriptor<T>) -> Int { (try? modelContext.fetchCount(d)) ?? -1 }
        let pending = count(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "pending" }))
        let failed = count(FetchDescriptor<Chunk>(predicate: #Predicate { $0.status == "failed" }))
        let conversations = count(FetchDescriptor<Conversation>())
        let people = count(FetchDescriptor<Person>())
        let items = count(FetchDescriptor<ActionItem>())
        return "Recordings waiting: \(pending), failed: \(failed)\nConversations: \(conversations)\nPeople: \(people)\nList items: \(items)"
    }

    /// Listening's paused: the conversation going on is over.
    func closeLatest() {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let c = (try? modelContext.fetch(d))?.first, !c.closed else { return }
        c.closed = true
        try? modelContext.save()
    }

    func latestThreads() -> [TopicThread] {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return (try? modelContext.fetch(d))?.first?.threads ?? []
    }

    /// The transcript lines said while [thread] was the topic.
    func lines(of thread: TopicThread, in id: UUID) -> String {
        guard let c = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first else { return "" }
        let cal = Calendar.current
        func secondOfDay(_ d: Date) -> Int { let x = cal.dateComponents([.hour, .minute, .second], from: d); return x.hour! * 3600 + x.minute! * 60 + x.second! }
        let from = secondOfDay(thread.start), to = secondOfDay(thread.end) + 1
        func at(_ line: Substring) -> Int? {
            guard line.count > 9, line.hasPrefix("["), let h = Int(line.dropFirst(1).prefix(2)), let m = Int(line.dropFirst(4).prefix(2)),
                  let s = Int(line.dropFirst(7).prefix(2)) else { return nil }
            return h * 3600 + m * 60 + s
        }
        // A line covers everything until the next one starts, so a topic that began part-way
        // through a long line includes that line.
        let lines = c.transcript.split(separator: "\n")
        let starts = lines.map(at)
        var kept: [Substring] = []
        for (i, line) in lines.enumerated() {
            guard let t = starts[i] else { continue }
            let next = starts[(i + 1)...].compactMap { $0 }.first ?? Int.max
            if t < to && next > from { kept.append(line) }
        }
        return kept.joined(separator: "\n")
    }

    /// What the AI needs for any other question: the day's notes and the best-matching transcript.
    func notes(for question: String, focus: UUID?) -> (notes: [(label: String, title: String?, summary: String?)], best: (label: String, transcript: String)?) {
        let all = (try? modelContext.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.start, order: .reverse)]))) ?? []
        let pool = focus.map { id in all.filter { $0.id == id } } ?? Array(all.prefix(40))
        let keys = Prompts.keywords(question)
        let best = pool.max { a, b in score(a, keys) < score(b, keys) }
        let notes = pool.prefix(12).map { (label: label($0), title: $0.title, summary: $0.summary) }
        return (notes: notes, best: best.map { (label: label($0), transcript: $0.transcript) })
    }

    func deleteConversation(_ id: UUID) {
        let optional: UUID? = id
        try? modelContext.delete(model: Conversation.self, where: #Predicate { $0.id == id })
        try? modelContext.delete(model: Chunk.self, where: #Predicate { $0.conversationID == optional })
        try? modelContext.save()
    }

    func deleteEverything() {
        try? modelContext.delete(model: Conversation.self)
        try? modelContext.delete(model: Chunk.self)
        try? modelContext.delete(model: ActionItem.self)
        try? modelContext.delete(model: Person.self)
        try? modelContext.save()
        try? FileManager.default.removeItem(at: Recorder.audioDirectory)
    }

    // MARK: - Naming voices

    /// "Speaker 2 is Sarah" (or "that's me"): renames their lines, remembers their voice, and finds
    /// them in your other conversations. Returns the name used and how many others they were in.
    func nameVoice(in id: UUID, label: String, as typed: String) -> (name: String, elsewhere: Int)? {
        guard let name = Labels.cleanName(typed), name != label,
              let c = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first
        else { return nil }
        let isMe = name == Labels.me
        let heard = c.voiceprints.first { $0.label == label }
        let people = (try? modelContext.fetch(FetchDescriptor<Person>())) ?? []
        var person = people.first { isMe ? $0.isMe : !$0.isMe && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if let heard {
            if let person { person.add(heard.print, seconds: heard.seconds) }
            else {
                let p = Person(name: isMe ? "Me" : name, print: heard.print, seconds: heard.seconds, isMe: isMe)
                modelContext.insert(p)
                person = p
            }
        }
        let shown = person?.voice.label ?? name
        relabel(c, from: label, to: shown)
        var elsewhere = 0
        if let voice = person?.voice {
            let all = (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? []
            for other in all where other.id != c.id && !other.voiceprints.contains(where: { $0.label == shown }) {
                if let match = VoiceMatcher.match(voice, in: other.voiceprints) {
                    relabel(other, from: match, to: shown)
                    elsewhere += 1
                }
            }
        }
        try? modelContext.save()
        return (shown, elsewhere)
    }

    /// A named person called something else, everywhere.
    func renamePerson(_ id: UUID, to typed: String) {
        guard let p = (try? modelContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.id == id })))?.first,
              !p.isMe, let name = Labels.cleanName(typed), name != Labels.me, name != p.name else { return }
        let old = p.name
        p.name = name
        for c in (try? modelContext.fetch(FetchDescriptor<Conversation>())) ?? [] where c.transcript.contains("] \(old): ") {
            relabel(c, from: old, to: name)
        }
        try? modelContext.save()
    }

    /// Stops recognising someone. Transcripts keep the name they were given.
    func forgetPerson(_ id: UUID) {
        try? modelContext.delete(model: Person.self, where: #Predicate { $0.id == id })
        try? modelContext.save()
    }

    private func relabel(_ c: Conversation, from: String, to: String) {
        c.transcript = Labels.rename(c.transcript, from: from, to: to)
        c.title = c.title.map { Labels.renameInText($0, from: from, to: to) }
        c.summary = c.summary.map { Labels.renameInText($0, from: from, to: to) }
        var voices = c.voiceprints
        if let i = voices.firstIndex(where: { $0.label == from }) {
            let moved = voices.remove(at: i)
            if let j = voices.firstIndex(where: { $0.label == to }) { voices[j].add(moved.print, seconds: moved.seconds) }
            else { voices.append(Voiceprint(label: to, print: moved.print, seconds: moved.seconds)) }
            c.voiceprints = voices
        }
    }

    // MARK: - Private

    private func score(_ c: Conversation, _ keys: [String]) -> Double {
        let notes = ((c.title ?? "") + " " + (c.summary ?? "")).lowercased()
        let text = c.transcript.lowercased()
        var s = 0.0
        for k in keys {
            if notes.contains(k) { s += 3 }
            s += Double(min(text.components(separatedBy: k).count - 1, 5))
        }
        return s + c.start.timeIntervalSince1970 / 1e10 // newer wins ties
    }

    private func label(_ c: Conversation) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(c.start) ? "'Today' HH:mm" : "EEE d MMM HH:mm"
        let e = DateFormatter(); e.dateFormat = "HH:mm"
        return "\(f.string(from: c.start))–\(e.string(from: c.end))"
    }

    /// The conversation a recording carries on, if it's soon enough after the last one.
    private func openConversation(for chunk: Chunk) -> Conversation? {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        guard let latest = (try? modelContext.fetch(d))?.first, !latest.closed,
              chunk.start.timeIntervalSince(latest.end) <= Double(gapMinutes) * 60 else { return nil }
        return latest
    }

    private func attach(_ chunk: Chunk, text: String, to open: Conversation?) -> Conversation {
        if let open {
            open.transcript += "\n" + text
            open.end = max(open.end, chunk.end)
            return open
        }
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        if let latest = (try? modelContext.fetch(d))?.first { latest.closed = true }
        let c = Conversation(start: chunk.start, end: chunk.end, transcript: text)
        modelContext.insert(c)
        return c
    }

    /// The words, each line labelled with its voice: you, someone you've named, or "Speaker N".
    /// Without the voice models, every line is just "Speech".
    private func whoSaidWhat(_ words: [SpeakerAlign.Word], split: VoiceEngine.Split?, voices: inout [Voiceprint],
                             before: String?, start: Date) -> [Utterance] {
        var turns: [SpeakerAlign.Turn] = []
        var fallback = Labels.anonymous
        if let split {
            let labels = VoiceMatcher.label(split.voices, heard: &voices, known: knownVoices())
            turns = split.turns.compactMap { t in labels[t.speaker].map { SpeakerAlign.Turn(start: t.start, end: t.end, speaker: $0) } }
            // Words the voices didn't cover: most likely whoever was speaking last.
            fallback = lastSpeaker(before).flatMap { $0 == Labels.anonymous ? nil : $0 } ?? turns.first?.speaker ?? Labels.numbered(1)
        }
        return SpeakerAlign.assign(words, turns: turns, fallback: fallback).compactMap { said in
            let text = TranscriptFormat.clean(said.text)
            return text.isEmpty ? nil : Utterance(start: start.addingTimeInterval(said.start), speaker: said.speaker, text: text)
        }
    }

    private func lastSpeaker(_ transcript: String?) -> String? {
        transcript?.split(separator: "\n").last.flatMap { TranscriptFormat.turn.whole(String($0))?[1] }
    }

    /// The thread map: which topic each new stretch of talk belongs to, and what got left hanging.
    private func followThreads() async {
        guard Brain.notReadyReason == nil else { toFollow = []; return }
        while !toFollow.isEmpty {
            let next = toFollow.removeFirst()
            let id = next.id
            guard let c = (try? modelContext.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })))?.first else { continue }
            let text = await correctMisheard(next.text, in: c)
            let before = c.transcript.hasSuffix(text) ? String(c.transcript.dropLast(text.count)) : ""
            let prompt = Threads.prompt(c.threads, recent: before, new: text)
            guard let change = await withDeadline(40, { await Log.attempt("Thread map", { try await Brain.topic(prompt) }) }) else { continue }
            c.threads = Threads.apply(change, to: c.threads, from: next.from, to: next.to)
            try? modelContext.save()
            await showTrail(of: c)
        }
    }

    /// "Bucked the back room" → "booked": the AI fixes words the recogniser misheard, from
    /// context; a fix is only kept if it changes a few words and leaves the rest as said.
    private func correctMisheard(_ text: String, in c: Conversation) async -> String {
        let lines = text.split(separator: "\n").map(String.init)
        guard !lines.isEmpty, c.transcript.contains(text),
              let proposed = await withDeadline(30, { await Log.attempt("Correcting misheard words", { try await Brain.correct(lines) }) })
        else { return text }
        let fixed = Corrections.apply(proposed, to: lines).joined(separator: "\n")
        guard fixed != text else { return text }
        c.transcript = c.transcript.replacingOccurrences(of: text, with: fixed)
        try? modelContext.save()
        Log.info("Corrected misheard words in \(zip(lines, fixed.split(separator: "\n")).filter { $0.0 != String($0.1) }.count) line(s)")
        await suggest(for: c, found: ruleActions(c))
        return fixed
    }

    /// Puts the latest conversation's trail on the Lock Screen and in the Dynamic Island.
    private func showTrail(of c: Conversation) async {
        let threads = c.threads
        await MainActor.run { ListeningActivity.shared.show(threads) }
    }

    /// Tells the recogniser the names and words it should expect.
    private func refreshVocabulary() async {
        let people = ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).filter { !$0.isMe }.map(\.name)
        let items = ((try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "accepted" || $0.status == "suggested" }))) ?? []).map(\.title)
        await SpeechEngine.shared.setVocabulary(Vocabulary.words(people: people, items: items))
    }

    private func knownVoices() -> [KnownVoice] {
        ((try? modelContext.fetch(FetchDescriptor<Person>())) ?? []).map(\.voice)
    }

    private func ruleActions(_ c: Conversation) -> [ExtractedAction] {
        // Once WTF knows your voice, to-dos are what you said you'd do; until then, any line could be yours.
        ActionRules.ruleActions(ActionRules.candidateLines(c.transcript), conversationStart: c.start, title: c.title,
                                youOnly: c.transcript.contains("] \(Labels.me): "))
    }

    private func summarise(_ c: Conversation) async {
        guard Brain.notReadyReason == nil else {
            c.closed = true
            try? modelContext.save()
            return
        }
        c.threads = Threads.close(c.threads)
        do {
            let transcript = c.transcript
            guard let notes = await withDeadline(60, { await Log.attempt("Summary", { try await Brain.summarise(transcript) }) })
            else { throw StepTimedOut(what: "summarising") }
            c.title = notes.title
            c.summary = notes.points.map { "\u{2022} " + $0 }.joined(separator: "\n")
            c.closed = true
            try? modelContext.save()
            let lines = ActionRules.candidateLines(c.transcript)
            guard !lines.isEmpty else { return }
            let recent = Array(lines.suffix(60)), start = c.start
            guard let found = await withDeadline(60, { await Log.attempt("List items", { try await Brain.actions(lines: recent, start: start) }) })
            else { throw StepTimedOut(what: "finding list items") }
            let fromModel = ActionRules.fromModel(
                buy: found.buy, todo: found.todo,
                events: found.appointments.map { ($0.what, $0.when, $0.place, $0.booked) }, conversationStart: c.start, lines: recent)
            await suggest(for: c, found: ActionRules.merge(fromModel, ruleActions(c)))
        } catch {
            // Too long, or the model declined: keep the conversation, untitled.
            Log.error("Couldn't summarise a \(c.transcript.count)-character conversation", error)
            c.closed = true
            try? modelContext.save()
        }
    }

    /// Suggests what's new: not on the list already, and not already suggested from this conversation.
    private func suggest(for c: Conversation, found: [ExtractedAction]) async {
        guard !found.isEmpty else { return }
        let cid: UUID? = c.id
        let open = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "suggested" || $0.status == "accepted" }))) ?? []
        let mine = (try? modelContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.conversationID == cid }))) ?? []
        let known = open + mine
        var fresh: [ExtractedAction] = []
        for a in found where !known.contains(where: { $0.type == a.type.rawValue && ($0.title.lowercased() == a.title.lowercased() || ActionRules.similar($0.title, a.title)) })
            && !fresh.contains(where: { $0.type == a.type && $0.title.lowercased() == a.title.lowercased() }) {
            fresh.append(a)
        }
        for a in fresh {
            let heard = a.source.map { Self.heard($0, about: a, on: c.start) }
            let item = ActionItem(type: a.type.rawValue, title: a.title, start: a.resolved?.start(),
                                  allDay: a.resolved?.allDay ?? false, place: a.place, quote: heard?.quote ?? a.whenText, conversationID: cid)
            item.heardAt = heard?.at
            item.note = a.note
            modelContext.insert(item)
        }
        try? modelContext.save()
        guard !fresh.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = "WTF heard \(fresh.count) thing\(fresh.count == 1 ? "" : "s") to act on"
        content.body = fresh.prefix(3).map(\.title).joined(separator: ", ")
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Pipeline {
    /// Where a list item came from: the sentence of its line that says it, and when that was.
    nonisolated static func heard(_ line: String, about a: ExtractedAction, on day: Date) -> (quote: String, at: Date?) {
        let text = line.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        let sentences = text.split(whereSeparator: { ".?!".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let key = a.title + " " + (a.whenText ?? "")
        let best = sentences.max { ActionRules.overlap(key, $0) < ActionRules.overlap(key, $1) } ?? text
        var quote = best
        if let end = text.range(of: best)?.upperBound, end < text.endIndex, ".?!".contains(text[end]) { quote.append(text[end]) }
        if quote.count > 160 { quote = String(quote.prefix(157)) + "\u{2026}" }
        var at: Date?
        if let m = Rx(#"^\[(\d\d):(\d\d):(\d\d)\]"#).first(line) {
            at = Calendar.current.date(bySettingHour: Int(m[1])!, minute: Int(m[2])!, second: Int(m[3])!, of: day)
        }
        return (quote, at)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// A step that didn't finish in time.
struct StepTimedOut: LocalizedError {
    var what: String
    var errorDescription: String? { "Gave up \(what): it took too long" }
}
