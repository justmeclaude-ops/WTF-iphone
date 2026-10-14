import AppIntents

// The actions behind the controls (Control Center, the Lock Screen's corners, the Action button)
// and the buttons on the Lock Screen card. They're in the app and its widget extension; as Live
// Activity intents, iOS runs them in the app, which doesn't open. In the extension they're only
// there to be named, so their bodies there do nothing.

/// What you were just saying (press again for what came before; starts listening if it's off).
struct WTFAskControlIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "What Was I Saying?"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        _ = await AppModel.shared.answerFromShortcut()
        #endif
        return .result()
    }
}

/// Listening on or off.
struct WTFListeningControlIntent: LiveActivityIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start or Stop Listening"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        _ = await AppModel.shared.toggleListeningFromShortcut()
        #endif
        return .result()
    }
}

/// Your list, read out.
struct WTFListControlIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Read My List"
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if !WIDGET
        _ = await AppModel.shared.listFromShortcut()
        #endif
        return .result()
    }
}
