import AVFoundation

/// Reads an answer into your AirPods (or any headphones): for the Action button, so you hear
/// where you'd got to without looking at the phone.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    private let synthesizer = AVSpeechSynthesizer()
    private var finished: CheckedContinuation<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Headphones of any kind are the way sound is going out now.
    static var headphonesOn: Bool {
        let quiet: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { quiet.contains($0.portType) }
    }

    /// Says [text] and returns once it's been said (or after 60 s at most).
    func say(_ text: String) async {
        let session = AVAudioSession.sharedInstance()
        // While listening the session can already play and record; otherwise, just play.
        if !Recorder.shared.running {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text.replacingOccurrences(of: "\u{2026}", with: ", "))
        utterance.voice = Self.voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.prefersAssistiveTechnologySettings = true
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            finished = done
            synthesizer.speak(utterance)
            Task {
                try? await Task.sleep(for: .seconds(60))
                self.finish()
            }
        }
        if !Recorder.shared.running { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        Log.info("Read an answer aloud (\(text.count) characters)")
    }

    /// The best voice for the phone's English: a premium or enhanced British one if installed.
    private static var voice: AVSpeechSynthesisVoice? {
        let language = Locale.current.identifier.hasPrefix("en_GB") || Locale.current.region?.identifier == "GB" ? "en-GB" : AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    private func finish() {
        finished?.resume()
        finished = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finish() }
    }
}
