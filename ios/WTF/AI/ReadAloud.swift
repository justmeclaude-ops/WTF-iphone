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
        await say(text, voice: Self.voice, speed: Self.speed)
    }

    private func say(_ text: String, voice: AVSpeechSynthesisVoice?, speed: Double) async {
        let session = AVAudioSession.sharedInstance()
        // While listening the session can already play and record; otherwise, just play.
        if !Recorder.shared.running {
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true)
            } catch {
                Log.error("Couldn't get the headphones to read the answer out", error)
            }
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text.replacingOccurrences(of: "\u{2026}", with: ", "))
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed))
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

    /// Starts reading [text] out and returns straight away, so the answer can be shown while it's said.
    func start(_ text: String) {
        Task { await say(text) }
    }

    /// Settings › Read-Aloud Voice: a short sample in [voice] at [speed].
    func sample(_ voice: AVSpeechSynthesisVoice?, speed: Double) {
        Task { await say("You were telling them about booking the dentist for Thursday.", voice: voice, speed: speed) }
    }

    nonisolated static let voiceKey = "readAloudVoice"
    nonisolated static let speedKey = "readAloudSpeed"

    /// Your pick from Settings, or the best English voice on the phone.
    static var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return defaultVoice
    }

    static var speed: Double { UserDefaults.standard.object(forKey: speedKey) as? Double ?? 1.0 }

    /// The best voice for the phone's English: a premium or enhanced British one if installed.
    static var defaultVoice: AVSpeechSynthesisVoice? {
        let language = Locale.current.identifier.hasPrefix("en_GB") || Locale.current.region?.identifier == "GB" ? "en-GB" : AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Every English voice on the phone, best first; the novelty ones (Bells, Bubbles…) left out.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
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
