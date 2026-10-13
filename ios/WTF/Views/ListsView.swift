import EventKit
import EventKitUI
import SwiftData
import SwiftUI
import UIKit

/// Heard Today (suggestions waiting for a yes) and one To Do list: appointments first, soonest
/// at the top, then everything else, shopping included.
struct ListsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ActionItem.created, order: .reverse) private var items: [ActionItem]
    @State private var draft = ""
    @State private var ticking: Set<UUID> = []
    @State private var calendarItem: ActionItem?

    private var suggested: [ActionItem] { items.filter { $0.status == "suggested" } }
    private var todo: [ActionItem] {
        items.filter { $0.status == "accepted" }.sorted { a, b in
            if (a.type == "EVENT") != (b.type == "EVENT") { return a.type == "EVENT" }
            return (a.start ?? .distantFuture, b.created) < (b.start ?? .distantFuture, a.created)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !suggested.isEmpty {
                    Section {
                        ForEach(suggested) { s in
                            SuggestionRow(item: s, onAccept: { accept(s) }, onDismiss: { s.status = "dismissed"; save() })
                        }
                    } header: {
                        Text("Heard Today")
                    } footer: {
                        Text("Things WTF picked up in your conversations. Nothing is added until you say so.")
                    }
                }
                Section {
                    ForEach(todo) { item in
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
                        for i in offsets { context.delete(todo[i]) }
                        save()
                    }
                    HStack(spacing: 14) {
                        Image(systemName: "circle").font(.title2).foregroundStyle(.tertiary)
                        TextField("Add to-do", text: $draft).onSubmit(add)
                    }
                } header: {
                    HStack {
                        Text("To Do").font(.title2.bold()).foregroundStyle(.blue).textCase(nil)
                        Spacer()
                        if !todo.isEmpty {
                            ShareLink(item: "To do:\n" + todo.map { "\u{2022} \($0.title)" + (detail($0).map { " (\($0))" } ?? "") }.joined(separator: "\n")) {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                    }
                } footer: {
                    if todo.isEmpty { Text("Empty. WTF adds things here when you accept its suggestions.") }
                }
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

    private func add() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        context.insert(ActionItem(type: "TODO", title: t, status: "accepted"))
        draft = ""
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
            Image(systemName: icon).foregroundStyle(.white)
                .frame(width: 29, height: 29).background(color, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline)
                if let d = detail(item) { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                if item.type != "EVENT" { Text("Add to your to-dos?").font(.subheadline).foregroundStyle(.secondary) }
                if let quote = item.quote { Text("\u{201C}\(quote)\u{201D}").font(.footnote).foregroundStyle(.tertiary).lineLimit(2) }
                HStack {
                    Button(item.type == "EVENT" ? "Add to Calendar" : "Add", action: onAccept).buttonStyle(.borderedProminent)
                    Button("Dismiss", action: onDismiss).buttonStyle(.bordered)
                }
                .buttonBorderShape(.capsule)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String { item.type == "EVENT" ? "calendar" : item.type == "BUY" ? "cart" : "checklist" }
    private var color: Color { item.type == "EVENT" ? .red : item.type == "BUY" ? .green : .blue }
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
                    .foregroundStyle(ticking ? Color.blue : Color.secondary)
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
