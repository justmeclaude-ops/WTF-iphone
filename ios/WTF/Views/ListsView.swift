import EventKit
import EventKitUI
import SwiftData
import SwiftUI
import UIKit

/// Three lists, the way you'd keep them: Calendar, To-dos and Shopping. What WTF heard sits at
/// the top of each, waiting for a yes ("Add") or a "Not Now"; below it, what's on the list.
struct ListsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ActionItem.created, order: .reverse) private var items: [ActionItem]
    @State private var drafts: [String: String] = [:]
    @State private var ticking: Set<UUID> = []
    @State private var calendarItem: ActionItem?

    private struct ListGroup: Identifiable {
        var id: String, title: String, icon: String, empty: String, canAdd: Bool
    }

    private let groups = [
        ListGroup(id: "EVENT", title: "Calendar", icon: "calendar", empty: "Appointments and plans you mention appear here.", canAdd: false),
        ListGroup(id: "TODO", title: "To-dos", icon: "checklist", empty: "Things you say you'll do appear here.", canAdd: true),
        ListGroup(id: "BUY", title: "Shopping", icon: "cart", empty: "Things you need to buy appear here.", canAdd: true),
    ]

    private func suggested(_ type: String) -> [ActionItem] { items.filter { $0.status == "suggested" && $0.type == type } }
    private func listed(_ type: String) -> [ActionItem] {
        items.filter { $0.status == "accepted" && $0.type == type }.sorted { a, b in
            (a.start ?? .distantFuture, b.created) < (b.start ?? .distantFuture, a.created)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Text("Heard today and kept for later. Nothing goes on a list until you say so.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
                ForEach(groups) { group in section(group) }
            }
            .animation(.snappy, value: items.map(\.status))
            .navigationTitle("Lists")
            .toolbar { ToolbarItem(placement: .topBarLeading) { ListeningButton() } }
            .sheet(item: $calendarItem) { item in
                EventEditor(item: item) { saved in
                    if saved { item.status = "accepted"; save() }
                    calendarItem = nil
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private func section(_ group: ListGroup) -> some View {
        let waiting = suggested(group.id)
        let kept = listed(group.id)
        Section {
            ForEach(waiting) { s in
                SuggestionRow(item: s, onAccept: { accept(s) }, onDismiss: { s.status = "dismissed"; save() })
            }
            ForEach(kept) { item in
                CheckRow(item: item, ticking: ticking.contains(item.id)) { tick(item) }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.title }
                        if item.type == "EVENT" {
                            Button("Add to Calendar", systemImage: "calendar.badge.plus") { calendarItem = item }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { context.delete(item); save() }
                    }
            }
            .onDelete { offsets in
                for i in offsets { context.delete(kept[i]) }
                save()
            }
            if group.canAdd {
                HStack(spacing: 14) {
                    Image(systemName: "plus.circle").font(.title2).foregroundStyle(.tertiary)
                    TextField(group.id == "BUY" ? "Add to shopping" : "Add to-do", text: Binding(
                        get: { drafts[group.id] ?? "" }, set: { drafts[group.id] = $0 }))
                        .onSubmit { add(group.id) }
                }
            } else if waiting.isEmpty && kept.isEmpty {
                Text(group.empty).font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: group.icon).font(.headline).foregroundStyle(.secondary)
                Text(group.title).font(.title3.bold()).foregroundStyle(.primary).textCase(nil)
                Spacer()
                if !kept.isEmpty {
                    ShareLink(item: group.title + ":\n" + kept.map { "\u{2022} \($0.title)" + (detail($0).map { " (\($0))" } ?? "") }.joined(separator: "\n")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func accept(_ item: ActionItem) {
        if item.type == "EVENT" { calendarItem = item } else { item.status = "accepted"; save() }
    }

    /// Ticked items stay a moment, so a second tap can undo it.
    private func tick(_ item: ActionItem) {
        if ticking.contains(item.id) { ticking.remove(item.id); return }
        ticking.insert(item.id)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard ticking.contains(item.id) else { return }
            ticking.remove(item.id)
            item.status = "done"
            save()
        }
    }

    private func add(_ type: String) {
        let t = (drafts[type] ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        context.insert(ActionItem(type: type, title: t, status: "accepted"))
        drafts[type] = ""
        save()
    }

    private func save() { try? context.save() }
}

func detail(_ item: ActionItem) -> String? {
    guard item.type == "EVENT" else { return nil }
    var parts: [String] = []
    if let start = item.start {
        parts.append(item.allDay ? start.formatted(.dateTime.weekday(.wide).day().month(.wide))
                                 : start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
    }
    if let place = item.place { parts.append(place) }
    return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
}

struct SuggestionRow: View {
    let item: ActionItem
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle").font(.footnote).foregroundStyle(.tertiary)
                .frame(width: 29, height: 29)
                .accessibilityLabel("Heard")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if let d = detail(item) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                if let quote = item.quote { Text("\u{201C}\(quote)\u{201D}").font(.footnote).foregroundStyle(.tertiary).lineLimit(2) }
                HStack {
                    Button(item.type == "EVENT" ? "Add to Calendar" : "Add", action: onAccept).buttonStyle(.bordered)
                    Button("Not Now", action: onDismiss).buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

}

/// A Reminders row: the ring fills with a dot when ticked.
struct CheckRow: View {
    let item: ActionItem
    let ticking: Bool
    let onTick: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onTick) {
                Image(systemName: ticking ? "largecircle.fill.circle" : "circle")
                    .font(.title2)
                    .foregroundStyle(ticking ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: ticking) { _, now in now }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(ticking ? .secondary : .primary)
                if let d = detail(item) { Text(d).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}

/// The system's "New Event" sheet, filled in. Since iOS 17 it needs no calendar permission.
struct EventEditor: UIViewControllerRepresentable {
    let item: ActionItem
    let done: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = item.title
        let start = item.start ?? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!.addingTimeInterval(9 * 3600)
        event.startDate = start
        event.endDate = item.allDay ? start : start.addingTimeInterval(3600)
        event.isAllDay = item.allDay
        event.location = item.place
        if let quote = item.quote { event.notes = "Heard by WTF: \u{201C}\(quote)\u{201D}" }
        let vc = EKEventEditViewController()
        vc.eventStore = store
        vc.event = event
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            done(action == .saved)
        }
    }
}
