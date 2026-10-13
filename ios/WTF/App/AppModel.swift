import AVFoundation
import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WTFCore

/// The app's shared state: listening, the chat, and the pipeline.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let container: ModelContainer
    let pipeline: Pipeline

    var recording = false
    var messages: [ChatMessage] = []
    /// What's happening while you wait ("Catching up…"), or nil.
    var status: String?
    /// The answer being written, word by word.
    var streaming: String?
    var tab = 0
    /// What's open on top of the Timeline and Settings tabs (for swiping between tabs).
    var timelinePath = NavigationPath()
    var settingsPath = NavigationPath()

    func pathIsEmpty(for tab: Int) -> Bool {
        switch tab {
        case 1: return timelinePath.isEmpty
        case 3: return settingsPath.isEmpty
        default: return true
        }
    }
    var problem: String?
    /// How far a transcription pass has got, while one's running.
    var transcribing: (done: Int, total: Int)?

    static let quickQuestion = "WTF was I just on about?"

    private init() {
        container = try! ModelContainer(for: Chunk.self, Conversation.self, ActionItem.self, Person.self)
        pipeline = Pipeline(modelContainer: container)
        let pipeline = pipeline
        Recorder.shared.onChunk = { url, start, end in
            Task {
                await pipeline.addChunk(url: url, start: start, end: end)
                await pipeline.run()
            }
        }
        Recorder.shared.onSpeech = { samples, chunk, offset in LiveTranscriber.shared.feed(samples, chunk: chunk, offset: offset) }
        // iOS doesn't always say when a call's over, so if listening hasn't come back in a few
        // minutes, a notification says so (and is withdrawn if it does come back).
        Recorder.shared.onInterrupted = {
            let content = UNMutableNotificationContent()
            content.title = "WTF has paused listening"
            content.body = "Something took the microphone. Open WTF to carry on."
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 180, repeats: false)
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: trigger))
        }
        Recorder.shared.onResumed = {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
        }
        Recorder.shared.onStopped = { [weak self] in
            Log.error("Listening stopped: couldn't get the microphone back")
            let content = UNMutableNotificationContent()
            content.title = "WTF stopped listening"
            content.body = "Something else took the microphone. Open WTF to carry on."
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [AppModel.pausedNotice])
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: AppModel.pausedNotice, content: content, trigger: nil))
            Task { @MainActor in
                self?.recording = false
                ListeningActivity.shared.stop()
                self?.problem = "Listening stopped: something else took the microphone. Tap to carry on."
            }
        }
    }

    func setListening(_ on: Bool) {
        if on {
            Task {
                guard await AVPermissions.microphone() else {
                    problem = "WTF needs the microphone: Settings › Privacy & Security › Microphone."
                    return
                }
                do {
                    try await SpeechEngine.shared.prepare()
                    // The voice models download once (about 22 MB) while you talk.
                    if VoiceEngine.enabled { Task.detached(priority: .utility) { try? await VoiceEngine.shared.prepare() } } // failures are logged inside
                    await LiveTranscriber.shared.start()
                    try Recorder.shared.start()
                    recording = true
                    ListeningActivity.shared.start()
                    problem = nil
                    UserDefaults.standard.set(true, forKey: "listening")
                } catch {
                    Log.error("Couldn't start listening", error)
                    problem = "Couldn't start listening: \(error.localizedDescription)"
                }
            }
        } else {
            Recorder.shared.stop()
            recording = false
            ListeningActivity.shared.stop()
            UserDefaults.standard.set(false, forKey: "listening")
            // The last recording's words are taken from the live transcript before it stops.
            // Pausing ends the conversation: it gets its title and summary now, not in five minutes.
            Task {
                await pipeline.run()
                await LiveTranscriber.shared.stop()
                await pipeline.closeLatest()
                await pipeline.run()
            }
        }
    }

    static let pausedNotice = "wtf.listening.paused"

    /// On opening the app: if listening should be on but the mic isn't running, start it again.
    func resumeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "listening") else { return }
        if !recording || !Recorder.shared.running {
            setListening(true)
        } else if Recorder.shared.stalled {
            Recorder.shared.resume(why: "on opening the app")
            if Recorder.shared.stalled {
                problem = "Listening stopped: something else has the microphone. Tap to carry on."
            } else {
                problem = nil
            }
        }
    }

    func processNow() {
        Task { await pipeline.run() }
    }

    func newChat() { messages = [] }

    /// From the Action button, a shortcut or Siri: go to Ask and ask the quick question.
    func askFromShortcut() {
        tab = 0
        ask(Self.quickQuestion)
    }

    func ask(_ question: String, focus: UUID? = nil) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, status == nil else { return }
        messages.append(ChatMessage(fromUser: true, text: q))
        Brain.prewarm()
        status = "Catching up on the last few seconds\u{2026}"
        Task {
            defer { status = nil; streaming = nil }
            // Close the chunk being recorded and transcribe it, so "just now" includes it (30 s at most).
            Recorder.shared.flush()
            let pipeline = pipeline
            if await withDeadline(20, { await pipeline.catchUp() }) == nil {
                Log.error("Catching up took over 20 s; answering from what's transcribed so far")
                messages.append(ChatMessage(fromUser: false, text: "The last few seconds are still being transcribed, so this may miss them."))
            }
            // Questions about the list are answered straight from it.
            if let direct = ListAnswers.answer(q, open: openItems()) {
                messages.append(ChatMessage(fromUser: false, text: direct))
                return
            }
            let intent = Prompts.intent(q)
            let now = Date()
            let latest = await pipeline.latestConversation()
            if focus == nil, intent == .latest {
                guard let latest else {
                    messages.append(ChatMessage(fromUser: false, text: "I haven't heard anything yet. Turn on listening and I'll keep track."))
                    return
                }
                // Word for word, straight away; the AI's gist follows.
                if let recap = QuickRecap.of(latest.transcript, start: latest.start, now: now) {
                    messages.append(ChatMessage(fromUser: false, text: recap))
                }
                guard Brain.notReadyReason == nil else { return }
                await answer(Prompts.latest(question: q, transcript: latest.transcript, topic: latest.title, now: now))
                return
            }
            if let why = Brain.notReadyReason {
                messages.append(ChatMessage(fromUser: false, text: why))
                return
            }
            let found = await pipeline.notes(for: q, focus: focus)
            guard !found.notes.isEmpty else {
                messages.append(ChatMessage(fromUser: false, text: "I haven't heard anything yet. Turn on listening and I'll keep track."))
                return
            }
            await answer(Prompts.focused(question: q, notes: found.notes, best: found.best, now: now))
        }
    }

    /// The answer to "what was I saying?", short enough to be read out in your ear.
    func spokenRecap() async -> String {
        Recorder.shared.flush()
        let pipeline = pipeline
        _ = await withDeadline(6) { await pipeline.catchUp() }
        guard let latest = await pipeline.latestConversation() else {
            return recording ? "I haven't heard anything yet." : "I'm not listening at the moment. Open WTF to turn listening on."
        }
        let now = Date()
        let threads = await pipeline.latestThreads()
        if Brain.notReadyReason == nil {
            let hanging = Threads.hanging(threads).first.map { "\($0.title): \($0.leftAt ?? "")" }
            let topic = threads.last(where: { $0.status == .current })?.title ?? latest.title
            if let gist = await Brain.quick(Prompts.spoken(transcript: latest.transcript, topic: topic, leftAt: hanging, now: now), seconds: 5),
               !gist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return gist.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return QuickRecap.spoken(latest.transcript, start: latest.start, now: now) ?? "I haven't heard anything yet."
    }

    /// Tapping a topic on the trail: where you'd got to with it.
    func askAbout(_ thread: TopicThread, in conversation: UUID) {
        guard status == nil else { return }
        tab = 0
        messages.append(ChatMessage(fromUser: true, text: "Where was I with \u{201C}\(thread.title)\u{201D}?"))
        Task {
            let lines = await pipeline.lines(of: thread, in: conversation)
            var reply = ""
            if let left = thread.leftAt, !left.isEmpty {
                reply = left.prefix(1).uppercased() + left.dropFirst()
                if !".?!".contains(reply.last ?? ".") { reply += "." }
            }
            if let recap = QuickRecap.of(lines, start: thread.start, now: Date()) {
                reply += (reply.isEmpty ? "" : "\n\n") + recap
            }
            messages.append(ChatMessage(fromUser: false, text: reply.isEmpty ? "I can't find what was said about that." : reply))
        }
    }

    private func answer(_ prompt: String) async {
        status = "Thinking\u{2026}"
        var text = ""
        do {
            for try await soFar in Brain.ask(prompt) {
                text = soFar
                streaming = soFar
            }
            streaming = nil
            messages.append(ChatMessage(fromUser: false, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            Log.error("Apple Intelligence couldn't answer", error)
            streaming = nil
            if !text.isEmpty { messages.append(ChatMessage(fromUser: false, text: text)) }
            messages.append(ChatMessage(fromUser: false, text: "Apple Intelligence couldn't answer that one (\(error.localizedDescription)).", isError: true))
        }
    }

    private func openItems() -> [ListAnswers.Item] {
        let items = (try? container.mainContext.fetch(FetchDescriptor<ActionItem>(predicate: #Predicate { $0.status == "accepted" }))) ?? []
        return items.map { ListAnswers.Item(type: ActionType(rawValue: $0.type) ?? .todo, title: $0.title, start: $0.start, allDay: $0.allDay, place: $0.place) }
    }
}

enum AVPermissions {
    static func microphone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}
