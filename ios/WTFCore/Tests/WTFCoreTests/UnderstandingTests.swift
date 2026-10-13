import XCTest
@testable import WTFCore

final class DoubtsTests: XCTestCase {
    func w(_ text: String, _ c: Double?, _ alts: [String] = []) -> SpeakerAlign.Word {
        SpeakerAlign.Word(start: 0, end: 0, text: text, confidence: c, alternatives: alts)
    }

    func testOtherReadingsLineUpWithTheWordTheyReplace() {
        let top = ["We", " bucked", " the", " back", " room", " for", " half", " free."]
        let alts = Doubts.alternatives(top: top, others: [
            ["We", "booked", "the", "back", "room", "for", "half", "free."],
            ["We", "bucked", "the", "back", "room", "for", "half", "three."],
            ["We", "booked", "the", "back", "rooms", "for", "half", "past", "three"],
        ])
        XCTAssertEqual(alts[1], ["booked"])
        XCTAssertEqual(alts[7], ["three", "past three"])
        XCTAssertNil(alts[0])
    }

    func testUnsureWordsArePointedOutAndSureOnesProtected() {
        let words = [w("We", 0.98), w(" bucked", 0.41, ["booked"]), w(" the", 0.97), w(" room", 0.95), w(" Crown", 0.7)]
        let doubts = Doubts.of(words)
        XCTAssertEqual(doubts.map(\.word), ["bucked"])
        XCTAssertEqual(doubts.first?.alternatives, ["booked"])
        XCTAssertEqual(Doubts.protected(words), ["we", "the", "room"])
        XCTAssertTrue(Doubts.protected([w("hi", nil)]).isEmpty)
    }

    func testAFixCanChangeADoubtedWordButNotOneTheRecogniserWasSureOf() {
        let protected: Set<String> = ["we", "the", "back", "room", "at", "crown"]
        let heard = "We bucked the back room at the Crown on Saturday night"
        XCTAssertTrue(Corrections.accept("We booked the back room at the Crown on Saturday night", for: heard, protected: protected))
        XCTAssertFalse(Corrections.accept("We booked the front room at the Crown on Saturday night", for: heard, protected: protected))
        // Without confidences, as before.
        XCTAssertTrue(Corrections.accept("We booked the front room at the Crown on Saturday night", for: heard))
    }

    func testThePromptMentionsWhatTheRecogniserDoubted() {
        let p = Corrections.prompt(["[10:00:00] You: We bucked the back room."],
                                   doubts: [Doubt(word: "bucked", confidence: 0.4, alternatives: ["booked"])],
                                   known: ["Harrogate"], learned: [LearnedFix(heard: "shona", meant: "Siobhan")])
        XCTAssertTrue(p.contains("\u{201C}bucked\u{201D} (it also heard \u{201C}booked\u{201D})"), p)
        XCTAssertTrue(p.contains("Harrogate"))
        XCTAssertTrue(p.contains("\u{201C}shona\u{201D} for \u{201C}Siobhan\u{201D}"))
        XCTAssertTrue(p.hasSuffix("1. We bucked the back room."))
    }

    func testYourFixesAreLearned() {
        let pairs = Fixes.pairs(from: "We bucked the back room with Shona.", to: "We booked the back room with Siobhan.")
        XCTAssertEqual(pairs.map(\.heard), ["bucked", "shona"])
        XCTAssertEqual(pairs.map(\.meant), ["booked", "Siobhan"])
        var learned = Fixes.learn(pairs, into: [])
        learned = Fixes.learn([("shona", "Siobhan")], into: learned)
        XCTAssertEqual(learned.first, LearnedFix(heard: "shona", meant: "Siobhan", count: 2))
        XCTAssertEqual(learned.count, 2)
        XCTAssertTrue(Fixes.pairs(from: "the same words", to: "the same words").isEmpty)
    }
}

final class UnderstandingTests: XCTestCase {
    func testNamesFromHowPeopleAreAddressed() {
        let t = """
            [10:00:00] You: Right, shall we sort the party?
            [10:00:05] Speaker 2: I can ring the Crown tomorrow.
            [10:00:09] You: Thanks, Sarah. And what do you reckon, Tom?
            [10:00:14] Speaker 3: Saturday works for me.
            [10:00:20] Speaker 2: Tom, can you bring the projector?
            [10:00:24] Speaker 3: Yeah, no problem.
            [10:00:30] You: Honestly, Monday.
            """
        let names: Set<String> = ["Sarah", "Tom"]
        let hints = NameHints.suggest(t, isName: { names.contains($0) })
        XCTAssertEqual(hints.map(\.label), ["Speaker 2", "Speaker 3"])
        XCTAssertEqual(hints.map(\.name), ["Sarah", "Tom"])
        XCTAssertEqual(hints.last?.times, 2)
        // Already named voices and non-names aren't suggested.
        XCTAssertTrue(NameHints.suggest("[10:00:00] Sarah: Hi.\n[10:00:02] You: Thanks, Sarah.", isName: { names.contains($0) }).isEmpty)
    }

    func testMemoryIsTidiedAndReadable() {
        let m = ConversationMemory(people: ["Speaker 2: probably Sarah"], decided: ["Party at the Crown", "party at the Crown", " "],
                                   suggested: ["None"], todo: ["You: ring the garage to confirm the MOT"], facts: ["2 Nov, 7pm"]).cleaned()
        XCTAssertEqual(m.decided, ["Party at the Crown"])
        XCTAssertTrue(m.suggested.isEmpty)
        let text = m.text()
        XCTAssertTrue(text.contains("Decided:\n- Party at the Crown"))
        XCTAssertFalse(text.contains("Suggested"))
        XCTAssertTrue(Prompts.memory(.empty, new: "[10:00:00] You: Hello").contains("(none yet)"))
        XCTAssertTrue(Prompts.background(memory: m, facts: ["Mum's birthday is 2 November"]).contains("Things I know from other days:\n- Mum's birthday is 2 November"))
    }

    func testKnownFactsAreFoundWhenRelevantAndNotRepeated() {
        let facts = ["Mum's birthday is 2 November", "Tom wants the projector link", "The garage is on Wood Lane"]
        XCTAssertEqual(KnownFacts.relevant(facts, to: "What are we doing for mum's birthday?"), ["Mum's birthday is 2 November"])
        XCTAssertEqual(KnownFacts.fresh(["mum's birthday is on 2 November", "Sarah works at the library", "ok"], known: facts), ["Sarah works at the library"])
        XCTAssertEqual(KnownFacts.names(in: facts), ["November", "Wood", "Lane"])
    }

    func testAppointmentsAreCheckedAgainstTheCalendar() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/London")!
        func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        let entries = [CalendarCheck.Entry(title: "Dentist", start: at(20, 15, 30), allDay: false),
                       CalendarCheck.Entry(title: "MOT - Wood Lane garage", start: at(16, 9), allDay: false)]
        XCTAssertEqual(CalendarCheck.check(title: "Dentist appointment", start: at(20, 15, 30), allDay: false, against: entries, calendar: cal), .alreadyThere)
        XCTAssertEqual(CalendarCheck.check(title: "Dentist", start: at(21, 15, 30), allDay: false, against: entries, calendar: cal),
                       .differs("Your calendar has it on Tuesday 20 October at 3:30 pm"))
        XCTAssertEqual(CalendarCheck.check(title: "MOT", start: at(16, 14), allDay: false, against: entries, calendar: cal),
                       .differs("Your calendar has it at 9:00 am"))
        XCTAssertNil(CalendarCheck.check(title: "Vet appointment", start: at(20, 15, 30), allDay: false, against: entries, calendar: cal))
    }

    func testExcerptsKeepTheBestLinesInOrderWithTheirNeighbours() {
        let lines = (0..<20).map { "line \($0)" }
        var scores = [Double](repeating: 0, count: 20)
        scores[3] = 0.9; scores[15] = 0.8
        let e = Retrieval.excerpt(lines, scores: scores, budget: 40)
        XCTAssertEqual(e, "line 2\nline 3\nline 4\n(\u{2026})\nline 14\nline 15\nline 16")
        XCTAssertEqual(Retrieval.wordScore("where's the venue", "The venue is the Crown"), 1)
    }

    func testOnlyClearSongsAreSkipped() {
        let song = MusicFilter.Window(music: 0.9, singing: 0.7, speech: 0.4)
        let talkOverRadio = MusicFilter.Window(music: 0.45, singing: 0.1, speech: 0.85)
        XCTAssertTrue(MusicFilter.isSong(Array(repeating: song, count: 10)))
        XCTAssertFalse(MusicFilter.isSong(Array(repeating: song, count: 6) + Array(repeating: talkOverRadio, count: 4)))
        XCTAssertFalse(MusicFilter.isSong(Array(repeating: talkOverRadio, count: 10)))
        XCTAssertFalse(MusicFilter.isSong([song, song]))
    }

    func testJoinedRecordingsMapBackToTheClock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var j = JoinedAudio()
        j.add(length: 10, recorded: t0)
        j.add(length: 5, recorded: t0.addingTimeInterval(60))
        XCTAssertEqual(j.length, 15.5)
        XCTAssertEqual(j.time(at: 4), t0.addingTimeInterval(4))
        XCTAssertEqual(j.time(at: 12.5), t0.addingTimeInterval(62))
        XCTAssertEqual(j.time(at: 10.2), t0.addingTimeInterval(10))
        let old = "[10:00:00] You: one two three four five six seven eight nine ten"
        XCTAssertTrue(JoinedAudio.accept(old: old, new: "[10:00:00] You: one two three four\n[10:00:03] Speaker 1: five six seven eight nine ten"))
        XCTAssertFalse(JoinedAudio.accept(old: old, new: "[10:00:00] You: one two three"))
    }
}
