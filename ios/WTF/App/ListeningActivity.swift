import ActivityKit
import Foundation
import WTFCore

/// Keeps the Live Activity in step with listening and the thread map.
@MainActor
final class ListeningActivity {
    static let shared = ListeningActivity()

    /// Whether the part of WTF that draws the card, the pill and the controls (its widget
    /// extension) is installed: sideloading can leave it out, and then the pill's an empty black bar.
    static var drawable: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let found = try? FileManager.default.contentsOfDirectory(atPath: plugins.path) else { return false }
        return found.contains { $0.hasSuffix(".appex") }
    }

    /// Whether Live Activities are allowed for WTF (Settings › Apps › WTF › Live Activities).
    static var allowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    private var activity: Activity<ListeningAttributes>?
    private var state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)

    func start() {
        guard activity == nil, Self.allowed else { return }
        // Any left from before (WTF closed while it was listening) would show as a second pill.
        for old in Activity<ListeningAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)
        do {
            activity = try Activity.request(attributes: ListeningAttributes(), content: ActivityContent(state: state, staleDate: nil))
        } catch {
            Log.error("Lock Screen card didn't start", error)
        }
    }

    func stop() {
        activity = nil
        for ending in Activity<ListeningAttributes>.activities {
            Task { await ending.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// The latest conversation's topics.
    func show(_ threads: [TopicThread]) {
        guard AppModel.shared.recording else { return }
        state.trail = threads.suffix(4).map {
            ListeningAttributes.Step(title: $0.title, hanging: $0.status == .hanging, current: $0.status == .current)
        }
        state.topic = threads.last(where: { $0.status == .current })?.title
        state.hanging = Threads.hanging(threads).count
        // iOS ends a Live Activity after some hours; start another if so.
        if let a = activity, a.activityState == .ended || a.activityState == .dismissed { activity = nil }
        if activity == nil { start() }
        let content = ActivityContent(state: state, staleDate: nil)
        let current = activity
        Task { await current?.update(content) }
    }
}
