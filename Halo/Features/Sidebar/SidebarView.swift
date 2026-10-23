import SwiftUI
import SwiftData

struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountStore.self) private var account
    @Environment(ChatEngine.self) private var engine
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query(sort: \Persona.sortIndex) private var personas: [Persona]
    @Query private var usage: [UsageRecord]
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var todaySpend: Double {
        let start = Calendar.current.startOfDay(for: .now)
        return usage.filter { $0.date >= start }.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            personaList
            List {
                ForEach(groups, id: \.title) { group in
                    Section {
                        ForEach(group.items) { conversation in
                            row(conversation)
                        }
                    } header: {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if conversations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.text.bubble.right").font(.largeTitle)
                        Text("Your chats will appear here").font(.subheadline)
                    }
                    .foregroundStyle(Theme.textTertiary)
                }
            }
            footer
        }
        .background(Theme.elevated.ignoresSafeArea())
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let renaming { renaming.title = renameText; renaming.titleIsSet = true; try? app.context.save() }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var header: some View {
        HStack {
            Text("Halo").font(.title2.weight(.semibold))
            Spacer()
            Button { app.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.semibold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var personaList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(personas) { p in
                Button { app.newChat(persona: p) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: p.icon)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 30, height: 30)
                        Text(p.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { app.sheet = .personaEditor(p.id) } label: { Label("Edit persona", systemImage: "pencil") }
                }
            }
            Button { app.sheet = .personaEditor(nil) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").frame(width: 30, height: 30)
                    Text("New persona")
                    Spacer()
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            Divider().overlay(Theme.hairline).padding(.top, 8)
        }
        .padding(.horizontal, 6)
    }

    private func row(_ conversation: Conversation) -> some View {
        let selected = app.currentConversationID == conversation.id
        return Button { app.open(conversation) } label: {
            HStack(spacing: 10) {
                if conversation.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.textTertiary) }
                Text(conversation.title)
                    .font(.subheadline)
                    .foregroundStyle(selected ? Color.white : Theme.textPrimary.opacity(0.88))
                    .lineLimit(1)
                Spacer()
                if engine.isBusy(conversation) { Spinner(size: 11) }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.white.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)) : Color.clear.clipShape(RoundedRectangle(cornerRadius: 12)))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { withAnimation { app.delete(conversation) } } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button { conversation.isPinned.toggle(); try? app.context.save() } label: {
                Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
            }
            .tint(Color(white: 0.35))
        }
        .contextMenu {
            Button { renameText = conversation.title; renaming = conversation } label: { Label("Rename", systemImage: "pencil") }
            Button { conversation.isPinned.toggle(); try? app.context.save() } label: {
                Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            ShareLink(item: ExportService.markdown(for: conversation)) { Label("Share as Markdown", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { app.delete(conversation) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { app.sheet = .spend } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.headline)
                            .font(.headline.monospacedDigit())
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(account.balanceLabel) · today \(Money.format(todaySpend, compact: true))")
                            .font(.caption2)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
                .padding(10)
                .glassCard(cornerRadius: 20, interactive: true)
            }
            .buttonStyle(.plain)
            Button { app.sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(Motion.snappy, value: account.headline)
    }

    private struct ChatGroup {
        let title: String
        let items: [Conversation]
    }

    private var groups: [ChatGroup] {
        let cal = Calendar.current
        let now = Date()
        var pinned: [Conversation] = []
        var buckets: [(String, [Conversation])] = [("Today", []), ("Yesterday", []), ("Previous 7 days", []), ("Previous 30 days", [])]
        var older: [String: [Conversation]] = [:]
        var olderOrder: [String] = []
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "MMMM yyyy"
        for c in conversations {
            if c.isPinned { pinned.append(c); continue }
            let d = c.updatedAt
            if cal.isDateInToday(d) { buckets[0].1.append(c) }
            else if cal.isDateInYesterday(d) { buckets[1].1.append(c) }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 7 { buckets[2].1.append(c) }
            else if let days = cal.dateComponents([.day], from: d, to: now).day, days < 30 { buckets[3].1.append(c) }
            else {
                let key = monthFormatter.string(from: d)
                if older[key] == nil { olderOrder.append(key) }
                older[key, default: []].append(c)
            }
        }
        var result: [ChatGroup] = []
        if !pinned.isEmpty { result.append(ChatGroup(title: "Pinned", items: pinned)) }
        for (title, items) in buckets where !items.isEmpty { result.append(ChatGroup(title: title, items: items)) }
        for key in olderOrder { result.append(ChatGroup(title: key, items: older[key] ?? [])) }
        return result
    }
}
