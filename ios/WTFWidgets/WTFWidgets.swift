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

/// The two buttons on the Lock Screen card: the answer, and a pause.
struct CardButtons: View {
    var body: some View {
        HStack(spacing: 8) {
            Button(intent: WTFAskControlIntent()) {
                Label("What was I saying?", systemImage: "questionmark.bubble")
                    .frame(maxWidth: .infinity)
            }
            Button(intent: WTFListeningControlIntent()) {
                Label("Pause", systemImage: "pause.fill")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(.white)
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
                    Listening().padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(s.since, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(maxWidth: 56, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.topic ?? "Listening").font(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if s.trail.count > 1 { Trail(steps: s.trail) }
                        CardButtons()
                    }
                }
            } compactLeading: {
                Listening()
            } compactTrailing: {
                if s.hanging > 0 {
                    Text("\(s.hanging)").font(.caption2.bold()).foregroundStyle(.white)
                } else if let topic = s.topic {
                    Text(topic).font(.caption2).lineLimit(1).frame(maxWidth: 70)
                }
            } minimal: {
                Listening()
            }
            .widgetURL(URL(string: "wtf://ask"))
            .keylineTint(.green)
        }
        .supplementalActivityFamilies([.small])
    }
}

/// The green waveform that says it's listening.
struct Listening: View {
    var body: some View {
        Image(systemName: "waveform").foregroundStyle(.green)
            .symbolEffect(.variableColor.iterative, options: .repeating)
    }
}

struct LockScreenCard: View {
    @Environment(\.activityFamily) private var family
    let state: ListeningAttributes.ContentState

    var body: some View {
        if family == .small {
            // Apple Watch Smart Stack: just the topic and what's hanging.
            VStack(alignment: .leading, spacing: 4) {
                HStack { Listening(); Text(state.since, style: .timer).font(.caption2.monospacedDigit()) }
                Text(state.topic ?? "Listening").font(.headline).lineLimit(2)
                if state.hanging > 0 {
                    Text("\(state.hanging) left hanging").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Listening().font(.title3)
                    Text(state.topic ?? "Listening").font(.headline).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(state.since, style: .timer).font(.subheadline.monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.trailing).frame(maxWidth: 72)
                }
                if state.trail.count > 1 { Trail(steps: state.trail) }
                CardButtons()
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
