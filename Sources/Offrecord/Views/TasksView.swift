import SwiftUI

/// One action item with the session it came from.
struct TaskItem: Identifiable {
    var record: SessionRecord
    var text: String
    var done: Bool

    var id: String { "\(record.id.uuidString)|\(text)" }

    @MainActor static func all(in store: SessionStore) -> [TaskItem] {
        _ = store.actionsVersion // refresh when items are ticked
        return store.sessions.flatMap { record -> [TaskItem] in
            guard let notes = store.notes(for: record) else { return [] }
            return notes.actionItems.map { TaskItem(record: record, text: $0, done: notes.isDone($0)) }
        }
    }
}

/// Every action item from every recording in one checklist.
struct TasksView: View {
    @Environment(AppModel.self) private var model
    @State private var showDone = false

    var body: some View {
        let items = TaskItem.all(in: model.store)
        let visible = items.filter { showDone || !$0.done }
        let groups = Dictionary(grouping: visible, by: { $0.record.id })
        let order = model.store.sessions.filter { groups[$0.id] != nil }

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("To-dos"))
                        .font(.title.weight(.semibold))
                    Text(L("%@ open", items.filter { !$0.done }.count))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle(L("Show completed"), isOn: $showDone)
                        .toggleStyle(.checkbox)
                }

                if order.isEmpty {
                    Text(items.isEmpty
                         ? L("To-dos from your recordings are collected here.")
                         : L("All done. 🎉"))
                        .foregroundStyle(.secondary)
                        .padding(.top, 30)
                        .frame(maxWidth: .infinity)
                }

                ForEach(order) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            model.selectedSessionID = record.id
                        } label: {
                            HStack(spacing: 6) {
                                Text(record.meta.title).font(.headline)
                                Text(record.meta.startedAt.formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.abbreviated)))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        ForEach(groups[record.id] ?? []) { item in
                            TaskRow(text: item.text, done: item.done) {
                                model.store.toggleAction(item.text, in: record)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct TaskRow: View {
    let text: String
    let done: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Text(text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
