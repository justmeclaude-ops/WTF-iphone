import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct WTFWidgets: WidgetBundle {
    var body: some Widget {
        ListeningLiveActivity()
        AskControl()
        ListeningControl()
        ListControl()
    }
}

// Controls: for Control Center, the two Lock Screen buttons (instead of the torch or camera), or
// the Action button. Each works without opening WTF.

struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.ask") {
            ControlWidgetButton(action: WTFAskControlIntent()) {
                Label("What Was I Saying?", systemImage: "questionmark.bubble")
            }
        }
        .displayName("What Was I Saying?")
        .description("Hear what you were just on about. Press again for what came before.")
    }
}

struct ListeningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.listening") {
            ControlWidgetButton(action: WTFListeningControlIntent()) {
                Label("WTF Listening", systemImage: "waveform")
            }
        }
        .displayName("Start or Stop Listening")
        .description("Turn WTF's listening on or off.")
    }
}

struct ListControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.wtf.ios.control.list") {
            ControlWidgetButton(action: WTFListControlIntent()) {
                Label("Read My List", systemImage: "checklist")
            }
        }
        .displayName("Read My List")
        .description("What's coming up, what to do and what to buy, read out.")
    }
}

/// The controls when you hold the listening pill (and on the Lock Screen card), laid out like
/// music's: back a step, what was I saying, stop. Each works without opening WTF.
struct PillControls: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            control(WTFBeforeControlIntent(), icon: "backward.fill", label: "Before that", size: 46)
            control(WTFAskControlIntent(), icon: "questionmark", label: "What was I saying?", size: 58)
            control(WTFListeningControlIntent(), icon: "stop.fill", label: "Stop", size: 46)
        }
        .frame(maxWidth: .infinity)
    }

    private func control<I: AppIntent>(_ intent: I, icon: String, label: String, size: CGFloat) -> some View {
        Button(intent: intent) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                Text(label).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningAttributes.self) { context in
            LockScreenCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "wtf://ask"))
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        RecordingDot()
                        Text("Recording").font(.caption.weight(.semibold)).foregroundStyle(.red)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Elapsed(since: s.since, font: .caption).frame(width: 56, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.topic ?? "Listening").font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if s.trail.count > 1 { Trail(steps: s.trail) }
                        PillControls().padding(.top, 2)
                    }
                }
            } compactLeading: {
                RecordingDot().padding(.leading, 2)
            } compactTrailing: {
                // A fixed width: a running time left to size itself fills the whole island.
                Elapsed(since: s.since, font: .caption2, alignment: .center).frame(width: 40)
            } minimal: {
                RecordingDot()
            }
            // A tap on the pill opens WTF to stop listening; holding it shows the buttons.
            .widgetURL(URL(string: "wtf://listening"))
            .keylineTint(.red)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The red dot that says WTF's recording, wherever the card or the pill shows.
struct RecordingDot: View {
    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9)
    }
}

/// How long it's been recording, in red like Voice Memos. Always given a width: a running time
/// takes all the room it's offered.
struct Elapsed: View {
    let since: Date
    let font: Font
    var alignment: TextAlignment = .trailing

    var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .font(font.monospacedDigit().weight(.semibold))
            .foregroundStyle(.red)
            .multilineTextAlignment(alignment)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

struct LockScreenCard: View {
    @Environment(\.activityFamily) private var family
    let state: ListeningAttributes.ContentState

    var body: some View {
        if family == .small {
            // Apple Watch Smart Stack: just the topic and what's hanging.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) { RecordingDot(); Elapsed(since: state.since, font: .caption2, alignment: .leading).frame(width: 44, alignment: .leading) }
                Text(state.topic ?? "Recording").font(.headline).lineLimit(2)
                if state.hanging > 0 {
                    Text("\(state.hanging) left hanging").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    RecordingDot()
                    Text(state.topic ?? "Recording").font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Elapsed(since: state.since, font: .subheadline).frame(width: 72, alignment: .trailing)
                }
                if state.trail.count > 1 { Trail(steps: state.trail) }
                PillControls()
            }
            .padding(16)
        }
    }
}

/// Mum's birthday › The MOT › That video: hanging topics glow orange, the current one is bold.
struct Trail: View {
    let steps: [ListeningAttributes.Step]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary) }
                Text(step.title)
                    .font(.caption.weight(step.current ? .semibold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(step.current ? 0.18 : 0.08)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])).opacity(step.hanging ? 1 : 0))
                    .foregroundStyle(.white)
            }
        }
    }
}
