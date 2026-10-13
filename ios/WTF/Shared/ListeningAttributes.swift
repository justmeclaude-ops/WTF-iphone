import ActivityKit
import Foundation

/// The Lock Screen / Dynamic Island card while WTF listens: the topic now and the trail that led
/// here, with anything left hanging marked. Shared by the app and its widget extension.
struct ListeningAttributes: ActivityAttributes {
    struct Step: Codable, Hashable {
        var title: String
        var hanging: Bool
        var current: Bool
    }

    struct ContentState: Codable, Hashable {
        /// What's being talked about now, once there's a topic.
        var topic: String?
        /// The last few topics, oldest first.
        var trail: [Step]
        /// Listening since.
        var since: Date
        /// How many topics are left hanging today.
        var hanging: Int
    }
}
