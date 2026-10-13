import Foundation
import FoundationModels
import WTFCore

@Generable
struct ConversationNotes {
    @Guide(description: "A short, specific title for the conversation, at most 6 words")
    var title: String
    @Guide(description: "2 to 5 short points: what was talked about, decided, or left unfinished")
    var points: [String]
}

@Generable
struct Appointment {
    @Guide(description: "What it is, e.g. Dentist check-up")
    var what: String
    @Guide(description: "When, in the words used, e.g. Thursday at half two; empty if not said")
    var when: String
    @Guide(description: "Where, or empty if not said")
    var place: String
}

@Generable
struct FoundActions {
    @Guide(description: "Groceries or household things to buy from a shop, one item each, e.g. Milk, AA batteries. Not meals out or takeaways")
    var buy: [String]
    @Guide(description: "Things the speaker said they would do, as short tasks, e.g. Ring the landlord")
    var todo: [String]
    @Guide(description: "Appointments or plans with a day or a time actually said, e.g. MOT at the garage, Thursday 9am")
    var appointments: [Appointment]
}

@Generable
struct CorrectedLines {
    @Guide(description: "Every line, numbered as given, with only clearly misheard words fixed")
    var lines: [String]
}

@Generable
struct TopicStep {
    @Guide(description: "The topics the new lines move through, in order, 1 to 4, each named in 2 to 5 words by what is being talked about, e.g. Where to eat tonight")
    var topics: [String]
    @Guide(description: "For each topic except the last, in the same order: true if it was dropped part-way, unfinished; false if it came to an end")
    var dropped: [Bool]
    @Guide(description: "If a topic was dropped part-way: what I was in the middle of saying about it, under 15 words, starting with 'you were'. Otherwise empty")
    var leftAt: String
    @Guide(description: "Which topic that was, exactly as named in topics. Empty if none was dropped")
    var leftAtTopic: String
    @Guide(description: "For each topic, in the same order: the key details said about it (dates, times, places, names) in under 8 words, e.g. 2 Nov, the Crown, Sat 7pm; or empty")
    var facts: [String]
}

/// Apple Intelligence's on-device model: summaries, list items and answers, free and private.
enum Brain {
    /// It's summarising what people said, so it shouldn't refuse because someone swore.
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    /// Nil when it's ready, otherwise what to do about it.
    static var notReadyReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This iPhone can't run Apple Intelligence, so WTF quotes what was said instead of summarising it."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri for summaries and answers."
            case .modelNotReady: return "Apple Intelligence is still getting ready (downloading). Summaries and answers will start once it's done."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
    }

    static func prewarm() {
        guard notReadyReason == nil else { return }
        LanguageModelSession(model: model, instructions: Prompts.instructions).prewarm()
    }

    static func summarise(_ transcript: String) async throws -> ConversationNotes {
        let session = LanguageModelSession(model: model, instructions: "You write short, plain notes about conversations the user had today.")
        return try await session.respond(to: Prompts.summary(transcript: transcript), generating: ConversationNotes.self).content
    }

    static func actions(lines: [String], start: Date) async throws -> FoundActions {
        let session = LanguageModelSession(model: model, instructions: "You pick out appointments, shopping and tasks from conversations. Only what was actually said.")
        return try await session.respond(to: Prompts.actions(lines: lines, conversationStart: start), generating: FoundActions.self).content
    }

    /// The lines with misheard words fixed from context (checked by Corrections before use).
    static func correct(_ lines: [String]) async throws -> [String] {
        let session = LanguageModelSession(model: model, instructions: "You fix words that speech recognition misheard, and change nothing else.")
        return try await session.respond(to: Corrections.prompt(lines), generating: CorrectedLines.self).content.lines
    }

    /// Which topic the newest lines belong to: the thread map's step.
    static func topic(_ prompt: String) async throws -> TopicChange {
        let session = LanguageModelSession(model: model, instructions: "You follow the topics of a conversation as it wanders, for someone who loses their train of thought.")
        let step = try await session.respond(to: prompt, generating: TopicStep.self).content
        return TopicChange(topics: step.topics, dropped: step.dropped, leftAt: step.leftAt, leftAtTopic: step.leftAtTopic, facts: step.facts)
    }

    /// A short answer to read aloud, given up on after [seconds].
    static func quick(_ prompt: String, seconds: Double) async -> String? {
        await withDeadline(seconds) {
            let session = LanguageModelSession(model: model, instructions: Prompts.instructions)
            return await Log.attempt("Spoken answer") { try await session.respond(to: prompt).content }
        }
    }

    /// The answer as it's written, each element the whole answer so far.
    static func ask(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: Prompts.instructions)
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
