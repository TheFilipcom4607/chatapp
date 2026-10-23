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
    @State private var query = ""
    @State private var hits: [ChatSearch.Hit] = []
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visible: [Conversation] { conversations.filter { !$0.isArchived } }
    private var archivedCount: Int { conversations.count - visible.count }

    private var todaySpend: Double {
        let start = Calendar.current.startOfDay(for: .now)
        return usage.filter { $0.date >= start }.reduce(0) { $0 + $1.cost }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            if !isSearching && !searchFocused { personaList }
            List {
                if isSearching {
                    let byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    ForEach(hits) { hit in
                        if let conversation = byID[hit.id] { row(conversation, hit: hit) }
                    }
                } else {
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
                    if archivedCount > 0 {
                        Button { app.sheet = .archived } label: {
                            Label("Archived (\(archivedCount))", systemImage: "archivebox")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 40)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if isSearching && hits.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.largeTitle)
                        Text("No chats match “\(query)”").font(.subheadline)
                    }
                    .foregroundStyle(Theme.textTertiary)
                } else if !isSearching && visible.isEmpty {
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
        .animation(Motion.snappy, value: isSearching || searchFocused)
        .task(id: query) {
            guard isSearching else { hits = []; return }
            try? await Task.sleep(nanoseconds: 180_000_000)   // let typing settle
            guard !Task.isCancelled else { return }
            hits = ChatSearch.run(query, conversations: conversations, context: app.context)
        }
        .onChange(of: app.sidebarOpen) { _, open in
            if !open { searchFocused = false }
        }
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
            Text("Halo").font(.display(.title2, weight: .semibold))
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
            TextField("Search chats", text: $query)
                .font(.subheadline)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty || searchFocused {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.fill, in: Capsule())
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
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

    private func row(_ conversation: Conversation, hit: ChatSearch.Hit? = nil) -> some View {
        let selected = app.currentConversationID == conversation.id
        return Button {
            app.open(conversation, revealing: hit?.messageID)
            searchFocused = false
        } label: {
            HStack(spacing: 10) {
                if conversation.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Theme.textTertiary) }
                if hit != nil && conversation.isArchived { Image(systemName: "archivebox").font(.caption2).foregroundStyle(Theme.textTertiary) }
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if hit != nil {
                            Text(ChatSearch.highlighted(conversation.title, query: query))
                        } else {
                            Text(conversation.title)
                        }
                    }
                    .font(.display(.callout))
                    .foregroundStyle(selected ? Color.white : Theme.textPrimary.opacity(0.88))
                    .lineLimit(1)
                    if let snippet = hit?.snippet {
                        Text(ChatSearch.highlighted(snippet, query: query))
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if engine.isBusy(conversation) { EclipseMark(size: 11, orbiting: true) }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white.opacity(0.08) : .clear)
                if selected {
                    Capsule().fill(Theme.corona).frame(width: 3, height: 16).padding(.leading, 6)
                }
            }
        )
        .listRowSeparator(.hidden)
        // Icons only: with titles the buttons are so wide the row has to slide most of the way over.
        .swipeActions(edge: .trailing) {
            if conversation.isArchived {
                Button { withAnimation { app.setArchived(conversation, false) } } label: { SwipeIcon("Unarchive", systemImage: "tray.and.arrow.up") }
                    .tint(Color(white: 0.35))
            } else {
                Button { withAnimation { app.setArchived(conversation, true) } } label: { SwipeIcon("Archive", systemImage: "archivebox") }
                    .tint(Color(white: 0.35))
            }
            Button(role: .destructive) { withAnimation { app.delete(conversation) } } label: { SwipeIcon("Delete", systemImage: "trash") }
                .tint(Theme.negative)
        }
        .swipeActions(edge: .leading) {
            Button { withAnimation { app.togglePin(conversation) } } label: {
                SwipeIcon(conversation.isPinned ? "Unpin" : "Pin", systemImage: conversation.isPinned ? "pin.slash" : "pin")
            }
            .tint(Color(white: 0.35))
        }
        .contextMenu {
            Button { renameText = conversation.title; renaming = conversation } label: { Label("Rename", systemImage: "pencil") }
            Button { withAnimation { app.togglePin(conversation) } } label: {
                Label(conversation.isPinned ? "Unpin" : "Pin", systemImage: "pin")
            }
            if conversation.isPinned && !isSearching {
                let pinned = AppModel.pinOrdered(visible.filter(\.isPinned))
                if pinned.first?.id != conversation.id {
                    Button { withAnimation { app.movePinned(conversation, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
                }
                if pinned.last?.id != conversation.id {
                    Button { withAnimation { app.movePinned(conversation, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
                }
            }
            Button { withAnimation { app.setArchived(conversation, !conversation.isArchived) } } label: {
                Label(conversation.isArchived ? "Unarchive" : "Archive", systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox")
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
                            .font(.readout(.headline, weight: .semibold))
                            .contentTransition(.numericText())
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(account.balanceLabel) · today \(Money.format(todaySpend, compact: true))")
                            .font(.readout())
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
        for c in visible {
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
        if !pinned.isEmpty { result.append(ChatGroup(title: "Pinned", items: AppModel.pinOrdered(pinned))) }
        for (title, items) in buckets where !items.isEmpty { result.append(ChatGroup(title: title, items: items)) }
        for key in olderOrder { result.append(ChatGroup(title: key, items: older[key] ?? [])) }
        return result
    }
}

/// A swipe action's label: the icon alone, with the title for VoiceOver.
struct SwipeIcon: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Image(systemName: systemImage).accessibilityLabel(title)
    }
}
