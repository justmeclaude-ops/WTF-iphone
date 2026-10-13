import ActivityKit
import Foundation
import WTFCore

/// Keeps the Live Activity in step with listening and the thread map.
@MainActor
final class ListeningActivity {
    static let shared = ListeningActivity()

    private var activity: Activity<ListeningAttributes>?
    private var state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)

    func start() {
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        state = ListeningAttributes.ContentState(topic: nil, trail: [], since: Date(), hanging: 0)
        do {
            activity = try Activity.request(attributes: ListeningAttributes(), content: ActivityContent(state: state, staleDate: nil))
        } catch {
            Log.error("Lock Screen card didn't start", error)
        }
    }

    func stop() {
        let ending = activity
        activity = nil
        Task { await ending?.end(nil, dismissalPolicy: .immediate) }
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
