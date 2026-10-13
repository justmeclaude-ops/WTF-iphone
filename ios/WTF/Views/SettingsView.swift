import SwiftData
import SwiftUI
import WTFCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("gapMinutes") private var gapMinutes = 5
    @AppStorage("keepDays") private var keepDays = 7
    @State private var speechReady: Bool?
    @State private var speechProblem: String?
    @State private var downloading = false
    @State private var confirmWipe = false
    @AppStorage("voices") private var voicesOn = true
    @AppStorage("voicesDownloaded") private var voicesDownloaded = false
    @State private var voicesLoading = false
    @State private var voicesFailed = false
    @Query(sort: \Person.name) private var people: [Person]

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.settingsPath) {
            Form {
                Section {
                    Toggle("Listen Continuously", isOn: Binding(get: { model.recording }, set: { model.setListening($0) }))
                } footer: {
                    Text("Only speech is kept: silence is never stored, and audio is deleted once it's transcribed. iPhones stop apps that are swiped away, so leave WTF open in the background.")
                }

                Section("On This iPhone") {
                    LabeledContent("Speech Recognition") {
                        if downloading { ProgressView() }
                        else if speechReady == true { Text("Ready").foregroundStyle(.green) }
                        else if speechReady == false { Button("Download") { download() } }
                        else { ProgressView() }
                    }
                    LabeledContent("Apple Intelligence") {
                        Text(Brain.notReadyReason == nil ? "Ready" : "Not available").foregroundStyle(Brain.notReadyReason == nil ? .green : .orange)
                    }
                    if let speechProblem { Text(speechProblem).font(.footnote).foregroundStyle(.red) }
                    if let why = Brain.notReadyReason { Text(why).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Toggle("Tell Voices Apart", isOn: $voicesOn)
                    if voicesOn {
                        LabeledContent("Voice Models") {
                            if voicesLoading { ProgressView() }
                            else if voicesDownloaded { Text("Ready").foregroundStyle(.green) }
                            else { Button(voicesFailed ? "Try Again" : "Download (22 MB)") { downloadVoices() } }
                        }
                        NavigationLink(value: "people") {
                            LabeledContent("People", value: people.isEmpty ? "None yet" : "\(people.count)")
                        }
                    }
                } header: {
                    Text("Voices")
                } footer: {
                    Text("Labels who said what. Tap a speaker in any transcript to say it\u{2019}s you or who they are, and WTF knows their voice from then on. Voiceprints stay on this iPhone.")
                }

                Section {
                    Stepper("New after \(gapMinutes) min of silence", value: $gapMinutes, in: 1...30)
                    Picker("Keep Transcripts", selection: $keepDays) {
                        ForEach([1, 3, 7, 14, 30, 90, 365], id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }
                } header: { Text("Conversations") }

                Section {
                    Text("Settings › Action Button › Shortcut › WTF › Ask WTF. Then a press of the Action button asks \u{201C}\(AppModel.quickQuestion)\u{201D}.")
                        .font(.callout)
                } header: { Text("Action Button") }

                Section {
                    NavigationLink("Diagnostics", value: "diagnostics")
                } footer: {
                    Text("If something's not working, share this so it can be fixed.")
                }

                Section {
                    Button("Delete All Recordings\u{2026}", role: .destructive) { confirmWipe = true }
                } footer: {
                    Text("Everything stays on this iPhone. Speech is transcribed and summarised on the device; nothing is uploaded.")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: String.self) { page in
                if page == "people" { PeopleView() } else { DiagnosticsView() }
            }
            .task { speechReady = await SpeechEngine.shared.isReady() }
            .confirmationDialog("Delete every conversation, transcript, list item and voice?", isPresented: $confirmWipe, titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive) { Task { await model.pipeline.deleteEverything() } }
            }
        }
    }

    private func downloadVoices() {
        voicesLoading = true
        voicesFailed = false
        Task {
            do { try await VoiceEngine.shared.prepare() } catch { voicesFailed = true }
            voicesDownloaded = VoiceEngine.downloaded
            voicesLoading = false
        }
    }

    private func download() {
        downloading = true
        Task {
            speechProblem = nil
            do {
                try await SpeechEngine.shared.prepare()
            } catch {
                Log.error("Speech model download", error)
                speechProblem = "The download failed: \(error.localizedDescription) Check Wi-Fi and free space, then try again."
            }
            speechReady = await SpeechEngine.shared.isReady()
            if speechReady == false && speechProblem == nil {
                let language = await SpeechEngine.shared.language()
                speechProblem = "iOS didn't install the speech model for \(language). Check Wi-Fi and free space (Settings › General › iPhone Storage), then try again."
            }
            downloading = false
        }
    }
}

/// The people WTF knows by voice: rename them, or forget them.
struct PeopleView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Person.name) private var people: [Person]
    @State private var renaming: Person?
    @State private var typed = ""

    var body: some View {
        List {
            ForEach(people) { p in
                Button {
                    guard !p.isMe else { return }
                    typed = p.name
                    renaming = p
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.isMe ? "person.crop.circle.fill" : "person.circle")
                            .font(.title2).foregroundStyle(VoiceColor.of(p.voice.label))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.isMe ? "You" : p.name).foregroundStyle(.primary)
                            Text(heard(p.seconds)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button("Forget", systemImage: "trash", role: .destructive) {
                        Task { await model.pipeline.forgetPerson(p.id) }
                    }
                }
            }
        }
        .overlay {
            if people.isEmpty {
                ContentUnavailableView("No One Yet", systemImage: "person.2.wave.2",
                                       description: Text("Tap a speaker\u{2019}s name in a transcript to say who they are."))
            }
        }
        .navigationTitle("People")
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $typed).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let p = renaming { Task { await model.pipeline.renamePerson(p.id, to: typed) } }
            }
        } message: {
            Text("Their lines in every conversation change too.")
        }
    }

    private func heard(_ seconds: Double) -> String {
        seconds < 60 ? "Voice learnt from \(Int(seconds)) seconds of speech"
            : "Voice learnt from \(Int(seconds / 60)) min of speech"
    }
}
