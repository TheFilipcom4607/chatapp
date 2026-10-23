import SwiftUI
import SwiftData

/// Chats hidden from the sidebar. Opening one is fine; sending a message brings it back.
struct ArchivedChatsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Conversation> { $0.archivedAt != nil }, sort: [SortDescriptor(\Conversation.archivedAt, order: .reverse)])
    private var archived: [Conversation]
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(archived) { conversation in
                    Button {
                        dismiss()
                        app.open(conversation)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(conversation.title)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if let date = conversation.archivedAt {
                                Text("Archived \(date.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.fill)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { withAnimation { app.delete(conversation) } } label: { Label("Delete", systemImage: "trash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { withAnimation { app.setArchived(conversation, false) } } label: {
                            Label("Unarchive", systemImage: "tray.and.arrow.up")
                        }
                        .tint(Color(white: 0.35))
                    }
                    .contextMenu {
                        Button { app.setArchived(conversation, false) } label: { Label("Unarchive", systemImage: "tray.and.arrow.up") }
                        Button(role: .destructive) { app.delete(conversation) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay {
                if archived.isEmpty {
                    ContentUnavailableView("No archived chats", systemImage: "archivebox",
                                           description: Text("Swipe a chat in the sidebar to archive it."))
                }
            }
            .navigationTitle("Archived")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !archived.isEmpty {
                        Menu {
                            Button { archived.forEach { app.setArchived($0, false) } } label: {
                                Label("Unarchive all", systemImage: "tray.and.arrow.up")
                            }
                            Button(role: .destructive) { confirmDeleteAll = true } label: {
                                Label("Delete all", systemImage: "trash")
                            }
                        } label: { Image(systemName: "ellipsis") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } }
            }
            .confirmationDialog("Delete all \(archived.count) archived chats?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { archived.forEach(app.delete) }
            }
        }
    }
}
