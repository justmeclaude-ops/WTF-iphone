import SwiftData
import SwiftUI
import UIKit
import WTFCore

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \Conversation.start, order: .reverse) private var conversations: [Conversation]
    @Query(filter: #Predicate<Chunk> { $0.status == "pending" }) private var pending: [Chunk]
    @State private var query = ""

    private var shown: [Conversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return conversations }
        return conversations.filter { c in
            [c.title, c.summary, c.transcript].contains { $0?.lowercased().contains(q) == true }
        }
    }

    private var byDay: [(String, [Conversation])] {
        var out: [(String, [Conversation])] = []
        for c in shown {
            let day = dayLabel(c.start)
            if out.last?.0 == day { out[out.count - 1].1.append(c) } else { out.append((day, [c])) }
        }
        return out
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.timelinePath) {
            List {
                if !pending.isEmpty || model.transcribing != nil {
                    Section { TranscribingRow(pending: pending.count) }
                }
                ForEach(byDay, id: \.0) { day, list in
                    Section(day) {
                        ForEach(list) { c in
                            NavigationLink(value: c) { ConversationRow(conversation: c) }
                                .contextMenu {
                                    Button("Ask About This", systemImage: "questionmark.bubble") {
                                        model.tab = 0
                                        model.ask(c.title.map { "What happened in \u{201C}\($0)\u{201D}?" } ?? "What was said then?", focus: c.id)
                                    }
                                    if let summary = c.summary {
                                        Button("Copy Summary", systemImage: "doc.on.doc") {
                                            UIPasteboard.general.string = [c.title, summary].compactMap { $0 }.joined(separator: "\n")
                                        }
                                    }
                                    ShareLink(item: shareText(c)) { Label("Share", systemImage: "square.and.arrow.up") }
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { await model.pipeline.deleteConversation(c.id) }
                                    }
                                }
                        }
                    }
                }
            }
            .overlay {
                if conversations.isEmpty && pending.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "waveform",
                                           description: Text("Turn on listening and your conversations will appear here."))
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "Search everything you've heard")
            .refreshable { await model.pipeline.run() }
            .navigationTitle("Timeline")
            .navigationDestination(for: Conversation.self) { ConversationView(conversation: $0) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { ListeningButton() } }
        }
    }
}

struct TranscribingRow: View {
    @Environment(AppModel.self) private var model
    let pending: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
                .frame(width: 29, height: 29)
            if let p = model.transcribing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.total > 1 ? "Transcribing \(p.done + 1) of \(p.total)\u{2026}" : "Transcribing\u{2026}")
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                }
                ProgressView()
            } else {
                Text("\(pending) segment\(pending == 1 ? "" : "s") waiting")
                Spacer()
                Button("Process Now") { model.processNow() }
                    .sensoryFeedback(.selection, trigger: model.transcribing != nil)
            }
        }
    }
}

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(displayTitle(conversation)).font(.headline).lineLimit(1)
                Spacer()
                if !conversation.closed && conversation.summary == nil {
                    Label("Live", systemImage: "circle.fill").font(.subheadline).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        .imageScale(.small)
                } else {
                    Text(conversation.start, format: .dateTime.hour().minute()).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var preview: String {
        if let first = conversation.summary?.split(separator: "\n").first {
            return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\u{2022}- "))
        }
        return conversation.transcript.split(separator: "\n").last.map { line in
            String(line).components(separatedBy: ": ").dropFirst().joined(separator: ": ")
        } ?? ""
    }
}

struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    @State private var confirmDelete = false
    /// The voice being named, and what's typed.
    @State private var naming: String?
    @State private var typed = ""
    @State private var note: String?
    @State private var saved = 0

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayTitle(conversation)).font(.title2.bold())
                    Text("\(dayLabel(conversation.start)), \(conversation.start.formatted(date: .omitted, time: .shortened))\u{2013}\(conversation.end.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
            }
            if let summary = conversation.summary, !summary.isEmpty {
                Section("Summary") { Text(summary) }
            }
            if !conversation.threads.isEmpty {
                Section("Threads") {
                    ThreadList(threads: conversation.threads) { model.askAbout($0, in: conversation.id) }
                }
            }
            Section {
                ForEach(Array(conversation.transcript.split(separator: "\n").enumerated()), id: \.offset) { _, line in
                    let parts = parse(String(line))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let who = parts.speaker {
                                Menu { voiceMenu(who) } label: {
                                    Text(who).font(.subheadline.weight(.semibold)).foregroundStyle(VoiceColor.of(who))
                                }
                            }
                            Text(parts.time).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(parts.text).textSelection(.enabled)
                    }
                }
            } header: {
                Text("Transcript")
            } footer: {
                if let note { Text(note) }
                else if hasUnnamedVoices { Text("Tap a speaker to say who it is. WTF will know their voice from then on.") }
            }
            Section {
                Button("Delete Conversation", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(conversation.start.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: shareText(conversation)) }
        .sensoryFeedback(.success, trigger: saved)
        .alert(naming.map { Labels.number($0) != nil ? "Who\u{2019}s \($0)?" : "Rename \($0)" } ?? "",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $typed).textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let label = naming { name(label, as: typed) } }
        } message: {
            Text("WTF will recognise their voice from now on, here and in your other conversations.")
        }
        .confirmationDialog("Delete this conversation?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { await model.pipeline.deleteConversation(conversation.id) }
                dismiss()
            }
        }
    }

    @ViewBuilder private func voiceMenu(_ who: String) -> some View {
        if who != Labels.me {
            Button("That\u{2019}s Me", systemImage: "person.crop.circle") { name(who, as: Labels.me) }
        }
        Button(Labels.number(who) != nil ? "Name This Voice\u{2026}" : "Rename\u{2026}", systemImage: "pencil") {
            typed = Labels.number(who) == nil && who != Labels.me ? who : ""
            naming = who
        }
    }

    private var hasUnnamedVoices: Bool {
        Labels.speakers(in: conversation.transcript).contains { Labels.number($0) != nil }
    }

    private func name(_ label: String, as typed: String) {
        let id = conversation.id
        Task {
            guard let done = await model.pipeline.nameVoice(in: id, label: label, as: typed) else { return }
            saved += 1
            let who = done.name == Labels.me ? "you" : done.name
            note = done.elsewhere > 0
                ? "Also found \(who) in \(done.elsewhere) other conversation\(done.elsewhere == 1 ? "" : "s")."
                : "WTF will recognise \(who) from now on."
        }
    }

    private func parse(_ line: String) -> (time: String, speaker: String?, text: String) {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return ("", nil, line) }
        let time = String(line[line.index(after: line.startIndex)..<close].prefix(5))
        let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard let colon = rest.range(of: ": ") else { return (time, nil, rest) }
        let who = String(rest[..<colon.lowerBound])
        let text = String(rest[colon.upperBound...])
        return (time, who == Labels.anonymous ? nil : who, text)
    }
}

/// Speakers in quiet type: you in full black (or white), everyone else in grey.
enum VoiceColor {
    static func of(_ label: String) -> Color { label == Labels.me ? .primary : .secondary }
}

/// Its title, or what's happening until it has one.
func displayTitle(_ c: Conversation) -> String {
    if let title = c.title { return title }
    if !c.closed { return "Listening\u{2026}" }
    return Brain.notReadyReason == nil ? "Summarising\u{2026}" : "Conversation"
}

func dayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
}

func shareText(_ c: Conversation) -> String {
    var s = (c.title ?? "Conversation") + "\n" + "\(dayLabel(c.start)), \(c.start.formatted(date: .omitted, time: .shortened))\n"
    if let summary = c.summary, !summary.isEmpty { s += "\n" + summary + "\n" }
    return s + "\n" + c.transcript
}
