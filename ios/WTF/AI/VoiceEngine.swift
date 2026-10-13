import FluidAudio
import Foundation
import WTFCore

/// "Who spoke when", on the phone: pyannote's speaker segmentation and WeSpeaker voiceprints,
/// converted for the Neural Engine (FluidAudio). The models (about 22 MB) download once.
actor VoiceEngine {
    static let shared = VoiceEngine()

    /// Settings › Tell Voices Apart.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "voices") as? Bool ?? true }
    /// The models are on the phone.
    static var downloaded: Bool { UserDefaults.standard.bool(forKey: "voicesDownloaded") }

    private var manager: OfflineDiarizerManager?

    /// Downloads the models the first time, then loads them (once).
    func prepare() async throws {
        guard manager == nil else { return }
        let m = OfflineDiarizerManager(config: .default)
        do { try await m.prepareModels() } catch {
            Log.error("Voice models didn't load", error)
            throw error
        }
        manager = m
        Log.info("Voice models ready")
        UserDefaults.standard.set(true, forKey: "voicesDownloaded")
    }

    struct Split {
        var turns: [SpeakerAlign.Turn]
        var voices: [LocalVoice]
    }

    /// The voices in a recording and when each spoke, or nil if voices are off, not downloaded
    /// yet, or the recording's too short to tell.
    func split(_ url: URL) async -> Split? {
        guard Self.enabled, Self.downloaded else { return nil }
        do {
            try await prepare()
            guard let manager else { return nil }
            let result = try await manager.process(url)
            let turns = result.segments.map {
                SpeakerAlign.Turn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
            }
            guard !turns.isEmpty else { return nil }
            let prints = result.speakerDatabase ?? [:]
            let voices = SpeakerAlign.totals(turns).compactMap { id, t -> LocalVoice? in
                guard let print = prints[id] ?? result.segments.first(where: { $0.speakerId == id })?.embedding, !print.isEmpty else { return nil }
                return LocalVoice(id: id, print: print, seconds: t.seconds, firstAt: t.firstAt)
            }
            return Split(turns: turns, voices: voices)
        } catch {
            Log.error("Couldn't tell the voices apart in \(url.lastPathComponent)", error)
            return nil
        }
    }
}
