import SwiftUI

/// Past chats, kept seven days from their last message.
struct HistorySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Group {
                if app.history.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Chats stay here for \(ConversationStore.retentionDays) days, then delete themselves."))
                } else {
                    List {
                        ForEach(app.history) { conversation in
                            Button {
                                app.open(conversation)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.title)
                                        .font(.body.weight(conversation.id == app.current.id ? .semibold : .regular))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    HStack(spacing: Theme.Space.xs) {
                                        if let entry = ModelCatalog.entry(id: conversation.modelId) {
                                            Text(entry.displayName)
                                        }
                                        Text("·")
                                        Text("\(conversation.messages.count) messages")
                                        Text("·")
                                        Text(expiry(conversation))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                }
                            }
                            .listRowBackground(Theme.surface)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { app.delete(conversation) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { app.delete(conversation) } label: {
                                    Label("Delete chat", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        app.newConversation()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !app.history.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) { confirmDeleteAll = true } label: {
                            Label("Delete all chats", systemImage: "trash")
                        }
                        .tint(Theme.danger)
                    }
                }
            }
            .confirmationDialog("Delete all chats?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) {
                    app.deleteAllConversations()
                    dismiss()
                }
            } message: {
                Text("This removes every chat from this phone now, instead of waiting \(ConversationStore.retentionDays) days.")
            }
        }
        .tint(Theme.accent)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 620)
        #endif
    }

    private func expiry(_ conversation: Conversation) -> String {
        let days = app.daysLeft(for: conversation)
        return days == 0 ? "deletes today" : "deletes in \(days) day\(days == 1 ? "" : "s")"
    }
}
