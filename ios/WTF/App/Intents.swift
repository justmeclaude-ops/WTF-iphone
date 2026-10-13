import AppIntents

/// "WTF?" from the Action button (or a Shortcut): without opening the app or unlocking. With
/// AirPods or headphones in, the answer is read into your ears; otherwise it shows at the top
/// of the screen. Either way it's waiting in Ask when you next open WTF.
struct AskWTFIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Ask WTF"
    static let description = IntentDescription("What you were just on about: read aloud if AirPods are in, shown on screen if not.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

// Both are audio-playback intents: iOS then lets them start speaking straight away from the
// background, rather than holding the sound back until the button's pressed again.

/// "What was I saying?" from the Action button, Siri or a Shortcut, without opening the app:
/// read into your ears if AirPods or headphones are in, shown at the top of the screen if not.
struct WhatWasISayingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let description = IntentDescription("What you were just on about: read into your AirPods if they're in, shown on screen if not.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.answerFromShortcut()
        return .result(dialog: "\(answer)")
    }
}

struct ToggleListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Pause Listening"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.shared.setListening(!AppModel.shared.recording)
        return .result()
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
        AppShortcut(intent: ToggleListeningIntent(), phrases: ["Toggle \(.applicationName) listening"],
                    shortTitle: "Listening", systemImageName: "waveform")
    }
}
