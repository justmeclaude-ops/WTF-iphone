import SwiftData
import SwiftUI
import UIKit
import WTFCore

struct AskView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var typing: Bool
    @Query(AskView.latest) private var latest: [Conversation]

    static var latest: FetchDescriptor<Conversation> {
        var d = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
        d.fetchLimit = 1
        return d
    }

    /// The latest conversation's trail, while it's fresh (the last three hours).
    private var trail: (id: UUID, threads: [TopicThread])? {
        guard let c = latest.first, c.end > Date().addingTimeInterval(-3 * 3600) else { return nil }
        let threads = c.threads
        return threads.isEmpty ? nil : (c.id, threads)
    }

    private let suggestions = [
        AppModel.quickQuestion,
        "What was I talking about with those two earlier?",
        "What did I say I'd do today?",
        "Summarise my day so far",
        "What do I need to buy?",
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if let problem = model.problem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                                .onTapGesture { model.setListening(true) }
                        }
                        if model.messages.isEmpty { welcome }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, m in
                            let next = i + 1 < model.messages.count ? model.messages[i + 1] : nil
                            Bubble(message: m, tail: next?.fromUser != m.fromUser)
                                .padding(.top, i > 0 && model.messages[i - 1].fromUser != m.fromUser ? 8 : 0)
                        }
                        if let s = model.streaming, !s.isEmpty {
                            Bubble(message: ChatMessage(fromUser: false, text: s), tail: true).padding(.top, 8)
                        } else if let status = model.status {
                            HStack(spacing: 10) {
                                TypingBubble()
                                Text(status).font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .animation(.snappy, value: model.messages)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: (model.streaming?.count ?? 0) / 60) { proxy.scrollTo("bottom") }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let trail {
                    ThreadTrail(threads: trail.threads) { model.askAbout($0, in: trail.id) }
                        .background(Color(.systemBackground))
                        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: trail?.threads.count)
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ListeningButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Chat", systemImage: "square.and.pencil") { model.newChat() }
                        .disabled(model.messages.isEmpty)
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lost the thread? Ask about anything you've said or heard while WTF was listening.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(suggestions, id: \.self) { q in
                    Button { model.ask(q) } label: {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                            Text(q).foregroundStyle(.primary)
                            Spacer()
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .contentShape(Rectangle())
                    }
                    if q != suggestions.last { Divider().padding(.leading, 44) }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 14))
        }
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask WTF", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassEffect(in: .rect(cornerRadius: 20))
                .onChange(of: typing) { if typing { Brain.prewarm() } }
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.bold())
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.status != nil)
            .sensoryFeedback(.impact(weight: .light), trigger: model.messages.count)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func send() {
        let q = input
        input = ""
        model.ask(q)
    }
}

/// An iMessage bubble: blue on the right for you, grey on the left for WTF.
struct Bubble: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let tail: Bool

    var body: some View {
        HStack {
            if message.fromUser { Spacer(minLength: 60) }
            Text(message.text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(message.fromUser ? Color(.systemBackground) : (message.isError ? Color.secondary : Color.primary))
                .background(
                    message.fromUser ? AnyShapeStyle(Color(.label)) : AnyShapeStyle(Color(.systemGray5)),
                    in: BubbleShape(fromUser: message.fromUser, tail: tail)
                )
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    if message.fromUser {
                        Button("Ask Again", systemImage: "arrow.clockwise") { model.ask(message.text) }
                    } else {
                        ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
                .textSelection(.enabled)
            if !message.fromUser { Spacer(minLength: 60) }
        }
    }
}

/// A rounded bubble, with the little curled tail on the last bubble of a run.
struct BubbleShape: Shape {
    let fromUser: Bool
    let tail: Bool

    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: 18, style: .continuous)
        guard tail else { return p }
        let x = fromUser ? r.maxX : r.minX
        let dir: CGFloat = fromUser ? 1 : -1
        var t = Path()
        t.move(to: CGPoint(x: x - dir * 14, y: r.maxY))
        t.addQuadCurve(to: CGPoint(x: x + dir * 5, y: r.maxY), control: CGPoint(x: x - dir * 2, y: r.maxY))
        t.addQuadCurve(to: CGPoint(x: x - dir * 2, y: r.maxY - 16), control: CGPoint(x: x - dir * 2, y: r.maxY - 4))
        t.closeSubpath()
        p.addPath(t)
        return p
    }
}

/// The grey "…" bubble while WTF is thinking.
struct TypingBubble: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.bold())
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Color(.systemGray5), in: BubbleShape(fromUser: false, tail: true))
    }
}
