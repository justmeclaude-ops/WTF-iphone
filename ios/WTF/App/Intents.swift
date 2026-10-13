import AppIntents

/// "WTF?" from the Action button (or a Shortcut): without opening the app or unlocking. With
/// AirPods or headphones in, the answer is read into your ears; otherwise it shows at the top
/// of the screen. Either way it's waiting in Ask when you next open WTF.
struct AskWTFIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask WTF"
    static let description = IntentDescription("What you were just on about: read aloud if AirPods are in, shown on screen if not.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        let answer = await model.spokenRecap()
        model.messages.append(ChatMessage(fromUser: true, text: AppModel.quickQuestion))
        model.messages.append(ChatMessage(fromUser: false, text: answer))
        if ReadAloud.headphonesOn {
            await ReadAloud.shared.say(answer)
            return .result(dialog: "Read out in your headphones.")
        }
        return .result(dialog: "\(answer)")
    }
}

/// "Hey Siri, WTF was I saying?": answered out loud (AirPods, CarPlay, a locked phone), without
/// opening the app.
struct WhatWasISayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let description = IntentDescription("Tells you out loud what you were just on about, without opening WTF.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = await AppModel.shared.spokenRecap()
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
