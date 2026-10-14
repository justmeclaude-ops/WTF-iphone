import AppIntents

/// "WTF?" from the Action button (or a Shortcut): without opening the app or unlocking. With
/// AirPods or headphones in, the answer is read into your ears; otherwise it shows at the top
/// of the screen. Either way it's waiting in Ask when you next open WTF.
struct AskWTFIntent: AudioPlaybackIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Ask WTF"
    static let description = IntentDescription("What you were just on about: read aloud if AirPods are in, shown on screen if not. Starts listening if it's off; press again for what came before.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

// Audio-playback intents: iOS lets them start speaking straight away from the background,
// rather than holding the sound back until the button's pressed again. Audio-recording too, so
// a press can start listening without opening the app.

/// "What was I saying?" from the Action button, Siri or a Shortcut, without opening the app:
/// read into your ears if AirPods or headphones are in, shown at the top of the screen if not.
/// If listening's off, a press starts it; pressed again soon after an answer, it goes a step
/// further back (see AppModel.answerFromShortcut).
struct WhatWasISayingIntent: AudioPlaybackIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let description = IntentDescription("What you were just on about, read into your AirPods if they're in. Press again for what came before; if WTF isn't listening, starts it.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

/// Listening on or off without opening the app.
struct ToggleListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.toggleListeningFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

struct StartListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.buttonPressedAt = Date()
        let started = await AppModel.shared.startListening()
        let answer = started ? "WTF is listening." : AppModel.shared.problem ?? "Couldn't start listening."
        return .result(dialog: "\(answer)")
    }
}

struct StopListeningIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppModel.shared.buttonPressedAt = Date()
        if AppModel.shared.recording { AppModel.shared.setListening(false) }
        return .result(dialog: "WTF has stopped listening.")
    }
}

/// What's coming up, to do and to buy: read out if headphones are in, shown if not.
struct ReadMyListIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Read My List"
    static let description = IntentDescription("What's coming up, what to do and what to buy, from what WTF heard and you kept.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.listFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

/// The choices in the WTF Menu.
enum WTFChoice: String, AppEnum {
    case saying, before, listening, list

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "WTF"
    static let caseDisplayRepresentations: [WTFChoice: DisplayRepresentation] = [
        .saying: DisplayRepresentation(title: "What was I saying?", image: .init(systemName: "questionmark.bubble")),
        .before: DisplayRepresentation(title: "What came before that?", image: .init(systemName: "arrow.uturn.backward")),
        .listening: DisplayRepresentation(title: "Start or stop listening", image: .init(systemName: "waveform")),
        .list: DisplayRepresentation(title: "Read my list", image: .init(systemName: "checklist")),
    ]
}

/// A menu: for the Action button (or Back Tap) if you'd rather choose each time than have one
/// press do the most likely thing. Set a choice when assigning it and it does that straight away.
struct WTFMenuIntent: AudioPlaybackIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "WTF Menu"
    static let description = IntentDescription("Choose: what you were saying, what came before, listening on or off, or your list.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Choice", requestValueDialog: "What do you need?")
    var choice: WTFChoice?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let pick: WTFChoice
        if let choice { pick = choice } else { pick = try await $choice.requestValue("What do you need?") }
        let answer: String
        switch pick {
        case .saying: answer = await AppModel.shared.answerFromShortcut()
        case .before: answer = await AppModel.shared.beforeThatFromShortcut()
        case .listening: answer = await AppModel.shared.toggleListeningFromShortcut()
        case .list: answer = await AppModel.shared.listFromShortcut()
        }
        return .result(dialog: "\(answer)")
    }
}

struct WTFShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: WhatWasISayingIntent(),
                    phrases: ["\(.applicationName) was I saying", "What was I saying in \(.applicationName)",
                              "\(.applicationName), what was I on about", "\(.applicationName) was I on about"],
                    shortTitle: "What Was I Saying?", systemImageName: "ear")
        AppShortcut(intent: AskWTFIntent(), phrases: ["Ask \(.applicationName)", "Open \(.applicationName) and ask"],
                    shortTitle: "WTF?", systemImageName: "questionmark.bubble")
        AppShortcut(intent: WTFMenuIntent(), phrases: ["\(.applicationName) menu", "Open the \(.applicationName) menu"],
                    shortTitle: "WTF Menu", systemImageName: "list.bullet")
        AppShortcut(intent: ReadMyListIntent(), phrases: ["Read my \(.applicationName) list", "What's on my \(.applicationName) list"],
                    shortTitle: "Read My List", systemImageName: "checklist")
        AppShortcut(intent: StartListeningIntent(), phrases: ["Start \(.applicationName)", "Start \(.applicationName) listening"],
                    shortTitle: "Start Listening", systemImageName: "waveform")
        AppShortcut(intent: StopListeningIntent(), phrases: ["Stop \(.applicationName)", "Stop \(.applicationName) listening"],
                    shortTitle: "Stop Listening", systemImageName: "pause")
        AppShortcut(intent: ToggleListeningIntent(), phrases: ["Toggle \(.applicationName) listening"],
                    shortTitle: "Listening On or Off", systemImageName: "waveform.circle")
    }
}
