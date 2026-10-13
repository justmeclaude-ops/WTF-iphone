import AVFoundation

/// Reads an answer into your AirPods (or any headphones): for the Action button, so you hear
/// where you'd got to without looking at the phone.
///
/// The speech is made into sound first and then played by the app itself, rather than handed to
/// iOS's speech service to play: from the background (the Action button with the app closed or
/// asleep) the service would sometimes say nothing at all. Played by the app, the sound keeps the
/// app awake until it's finished, and if making it fails that's known and it tries again.
@MainActor
final class ReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ReadAloud()

    private var synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected: AVAudioFormat?
    /// Each reading has a number, so a newer one stops an older one.
    private var reading = 0
    private var spoken: CheckedContinuation<Void, Never>?

    override private init() {
        super.init()
        synthesizer.delegate = self
        engine.attach(player)
    }

    /// Headphones of any kind are the way sound is going out now.
    static var headphonesOn: Bool {
        let quiet: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { quiet.contains($0.portType) }
    }

    private static var route: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }

    /// For the Action button: reads [text] out if headphones are the way sound is going, and
    /// returns once it's been said. False if there are no headphones (nothing is played).
    func sayIntoHeadphones(_ text: String) async -> Bool {
        let ownSession = prepareSession()
        guard Self.headphonesOn else {
            Log.info("Not read aloud: sound is going to \(Self.route), not headphones")
            if ownSession { releaseSession() }
            return false
        }
        await speak(text, voice: Self.voice, speed: Self.speed)
        if ownSession { releaseSession() }
        return true
    }

    /// Says [text] and returns once it's been said.
    func say(_ text: String) async {
        let ownSession = prepareSession()
        await speak(text, voice: Self.voice, speed: Self.speed)
        if ownSession { releaseSession() }
    }

    /// Settings › Read-Aloud Voice: a short sample in [voice] at [speed].
    func sample(_ voice: AVSpeechSynthesisVoice?, speed: Double) {
        Task {
            let ownSession = prepareSession()
            await speak("You were telling them about booking the dentist for Thursday.", voice: voice, speed: speed)
            if ownSession { releaseSession() }
        }
    }

    // MARK: - Sound

    /// While listening the session can already play (and record); otherwise it's set up just to
    /// play. True if it was set up here, so it's let go afterwards.
    private func prepareSession() -> Bool {
        guard !Recorder.shared.running else { return false }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            Log.error("Couldn't get the headphones ready to read the answer out", error)
        }
        return true
    }

    private func releaseSession() {
        guard !Recorder.shared.running else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func speak(_ text: String, voice: AVSpeechSynthesisVoice?, speed: Double) async {
        reading += 1
        let mine = reading
        player.stop()
        synthesizer.stopSpeaking(at: .immediate)
        let clean = text.replacingOccurrences(of: "\u{2026}", with: ", ")
        func utterance() -> AVSpeechUtterance {
            let u = AVSpeechUtterance(string: clean)
            u.voice = voice
            u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed))
            return u
        }
        // Made into sound here, then played here; a second go with a fresh synthesiser if the first
        // came back empty (it can, the first time after the app's been woken).
        var sound = await render(utterance())
        if sound.isEmpty {
            Log.error("Speech came back silent; trying again")
            synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            sound = await render(utterance())
        }
        guard mine == reading else { return }
        if !sound.isEmpty, await play(sound) {
            Log.info("Read an answer aloud into \(Self.route)")
            return
        }
        // Last resort: let iOS's speech service say it.
        Log.error("Couldn't play the speech; handing it to iOS to say into \(Self.route)")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            spoken = done
            synthesizer.speak(utterance())
            Task {
                try? await Task.sleep(for: .seconds(60))
                self.finishSpeaking()
            }
        }
    }

    /// The speech as sound, or nothing if the synthesiser didn't produce any within a few seconds.
    private func render(_ utterance: AVSpeechUtterance) async -> [AVAudioPCMBuffer] {
        let collected = Collected()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            collected.done = done
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collected.finish()
                    return
                }
                if let copy = Self.floatCopy(pcm) { collected.add(copy) }
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                collected.finish()
            }
        }
        return collected.buffers
    }

    /// Plays [sound] and returns once it's been heard (true), or false if it couldn't be played.
    private func play(_ sound: [AVAudioPCMBuffer]) async -> Bool {
        guard let format = sound.first?.format else { return false }
        if connected != format {
            engine.stop()
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = format
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.error("Couldn't start playing the speech", error)
            return false
        }
        let seconds = sound.reduce(0.0) { $0 + Double($1.frameLength) / format.sampleRate }
        let heard = Collected()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            heard.done = done
            for (i, buffer) in sound.enumerated() {
                if i == sound.count - 1 {
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in heard.finish() }
                } else {
                    player.scheduleBuffer(buffer, completionHandler: nil)
                }
            }
            player.play()
            Task {
                try? await Task.sleep(for: .seconds(seconds + 5))
                heard.finish()
            }
        }
        player.stop()
        engine.stop()
        return true
    }

    /// The synthesiser hands over its own buffers (sometimes 16-bit); a float copy the player can take.
    private nonisolated static func floatCopy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
              let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        do { try converter.convert(to: out, from: buffer) } catch { return nil }
        return out
    }

    /// Sound as it arrives from the synthesiser, and a wait that ends exactly once (when it's
    /// all there, or it's taken too long).
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var _buffers: [AVAudioPCMBuffer] = []
        var done: CheckedContinuation<Void, Never>?

        var buffers: [AVAudioPCMBuffer] { lock.lock(); defer { lock.unlock() }; return _buffers }

        func add(_ b: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if done != nil { _buffers.append(b) }
        }

        func finish() {
            lock.lock()
            let d = done
            done = nil
            lock.unlock()
            d?.resume()
        }
    }

    // MARK: - Voices

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

    // MARK: - iOS's speech service (the last resort)

    private func finishSpeaking() {
        spoken?.resume()
        spoken = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishSpeaking() }
    }
}
