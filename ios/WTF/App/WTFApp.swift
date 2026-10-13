import AppIntents
import SwiftUI
import UIKit
import UserNotifications

@main
struct WTFApp: App {
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .modelContainer(model.container)
                .task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    // Carry on listening if it was on when the app last ran.
                    Log.info("App started (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    model.resumeIfNeeded()
                    model.processNow()
                }
                // Tapping the Live Activity: "what was I saying?"
                .onOpenURL { url in
                    if url.host == "ask" { model.askFromShortcut() }
                }
        }
        .onChange(of: phase) { _, now in
            if now == .active {
                model.resumeIfNeeded()
                model.processNow()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Ask", systemImage: "bubble.left.and.text.bubble.right", value: 0) { AskView().modifier(TabSwipe()) }
            Tab("Timeline", systemImage: "clock", value: 1) { TimelineView().modifier(TabSwipe()) }
            Tab("Lists", systemImage: "checklist", value: 2) { ListsView().modifier(TabSwipe()) }
            Tab("Settings", systemImage: "gear", value: 3) { SettingsView().modifier(TabSwipe()) }
        }
        .sensoryFeedback(.selection, trigger: model.tab)
    }
}

/// Swipe left or right anywhere on a screen to go to the next or previous tab, as well as tapping
/// the tab bar. Not while a page is open on top (swiping right goes back there), not from the
/// screen's edge, and not when the swipe was scrolling something sideways (the thread trail).
struct TabSwipe: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Set by anything that scrolls sideways itself, so its swipes don't change tab.
    nonisolated(unsafe) static var sidewaysScrollUntil = Date.distantPast

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global).onEnded { drag in
                guard model.pathIsEmpty(for: model.tab), Date() > Self.sidewaysScrollUntil else { return }
                let dx = drag.translation.width, dy = drag.translation.height
                let width = UIScreen.main.bounds.width
                guard abs(dx) > abs(dy) * 2,
                      abs(dx) > 80 || abs(drag.predictedEndTranslation.width) > 200,
                      drag.startLocation.x > 24, drag.startLocation.x < width - 24 else { return }
                let next = model.tab + (dx < 0 ? 1 : -1)
                guard (0...3).contains(next) else { return }
                withAnimation(.snappy) { model.tab = next }
            }
        )
    }
}

/// Listening on or off, in words: a red "Start Listening" when it's off, a green breathing
/// "Listening" when it's on (tap to pause).
struct ListeningButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.recording {
                Button { model.setListening(false) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                        Text("Listening").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                }
                .accessibilityHint("Pauses listening")
            } else {
                Button { model.setListening(true) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Start Listening").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.recording)
    }
}
