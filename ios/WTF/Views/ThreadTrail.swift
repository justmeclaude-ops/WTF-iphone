import SwiftUI
import WTFCore

/// The thread map: the topics a conversation wandered through, left to right. Ones dropped
/// part-way glow orange; tap any to get back to where you were with it.
struct ThreadTrail: View {
    let threads: [TopicThread]
    let onTap: (TopicThread) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(threads.enumerated()), id: \.element.id) { i, t in
                        if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                        Button { onTap(t) } label: { ThreadChip(thread: t) }
                            .buttonStyle(.plain)
                            .id(t.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            // Scrolling the trail sideways shouldn't also change tab.
            .onScrollPhaseChange { _, phase in
                if phase != .idle { TabSwipe.sidewaysScrollUntil = Date().addingTimeInterval(0.6) }
            }
            .onAppear { proxy.scrollTo(threads.last?.id, anchor: .trailing) }
            .onChange(of: threads.count) { withAnimation(.snappy) { proxy.scrollTo(threads.last?.id, anchor: .trailing) } }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: threads.count)
    }
}

struct ThreadChip: View {
    let thread: TopicThread
    @State private var glow = false

    private var hanging: Bool { thread.status == .hanging }
    private var current: Bool { thread.status == .current }
    private var color: Color { hanging ? .orange : current ? .accentColor : .secondary }

    var body: some View {
        HStack(spacing: 5) {
            if hanging {
                Image(systemName: "ellipsis.bubble.fill")
            } else if current {
                Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Text(thread.title).lineLimit(1)
        }
        .font(.subheadline.weight(current ? .semibold : .regular))
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(color.opacity(hanging || current ? 0.15 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.orange, lineWidth: 1.5).opacity(hanging ? 1 : 0))
        .shadow(color: hanging ? .orange.opacity(glow ? 0.55 : 0.1) : .clear, radius: glow ? 8 : 2)
        .onAppear {
            guard hanging else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
        }
        .accessibilityLabel(thread.title + (hanging ? ", left hanging" : current ? ", talking about now" : ""))
    }
}

/// The threads as a list, for a conversation's page.
struct ThreadList: View {
    let threads: [TopicThread]
    let onTap: (TopicThread) -> Void

    var body: some View {
        ForEach(threads) { t in
            Button { onTap(t) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon(t)).foregroundStyle(t.status == .hanging ? Color.orange : t.status == .current ? .accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title).foregroundStyle(.primary)
                        if t.status == .hanging, let left = t.leftAt, !left.isEmpty {
                            Text(left.prefix(1).uppercased() + left.dropFirst()).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(t.start, format: .dateTime.hour().minute()).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func icon(_ t: TopicThread) -> String {
        switch t.status {
        case .hanging: return "ellipsis.bubble.fill"
        case .current: return "waveform"
        case .resumed: return "arrow.uturn.backward.circle"
        case .finished: return "checkmark.circle"
        }
    }
}
