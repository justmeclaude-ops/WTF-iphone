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
    @Guide(description: "Things to buy, one item each, e.g. Milk")
    var buy: [String]
    @Guide(description: "Things the speaker said they would do, as short tasks, e.g. Ring the landlord")
    var todo: [String]
    @Guide(description: "Appointments or plans that have a day or a time")
    var appointments: [Appointment]
}

@Generable
struct TopicStep {
    @Guide(description: "True if the new lines carry on the current topic")
    var sameTopic: Bool
    @Guide(description: "If the topic changed, or there is no topic yet: its name in 2 to 5 words, e.g. Mum's birthday present. Otherwise empty")
    var newTopic: String
    @Guide(description: "If the topic changed: true if the previous topic came to a natural end, false if it was dropped part-way")
    var previousFinished: Bool
    @Guide(description: "If the previous topic was dropped part-way: what I was in the middle of saying, under 15 words, starting with 'you were'. Otherwise empty")
    var leftAt: String
    @Guide(description: "If the new lines go back to one of the numbered earlier topics, its number; otherwise 0")
    var returnsTo: Int
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

    /// Which topic the newest lines belong to: the thread map's step.
    static func topic(_ prompt: String) async throws -> TopicChange {
        let session = LanguageModelSession(model: model, instructions: "You follow the topics of a conversation as it wanders, for someone who loses their train of thought.")
        let step = try await session.respond(to: prompt, generating: TopicStep.self).content
        return TopicChange(sameTopic: step.sameTopic, newTopic: step.newTopic, previousFinished: step.previousFinished,
                           leftAt: step.leftAt, returnsTo: step.returnsTo)
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
