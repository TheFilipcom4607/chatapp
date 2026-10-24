import SwiftUI

/// Reorder favorites, move them between everyday use and Trying out, or remove them.
struct FavoritesEditorView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var showBrowser = false

    private var everyday: [String] { settings.favoriteModelIDs.filter { !settings.isTrial($0) } }
    private var trying: [String] { settings.favoriteModelIDs.filter { settings.isTrial($0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(everyday, id: \.self) { row($0) }
                        .onMove { move(in: everyday, from: $0, to: $1, trying: false) }
                        .onDelete { remove(everyday, at: $0) }
                } header: {
                    Text("Everyday")
                }
                Section {
                    ForEach(trying, id: \.self) { row($0) }
                        .onMove { move(in: trying, from: $0, to: $1, trying: true) }
                        .onDelete { remove(trying, at: $0) }
                } header: {
                    Text("Trying out")
                } footer: {
                    Text(trying.isEmpty
                         ? "Models you're testing get their own group in the model menu. Tap a model's flask to move it here."
                         : "These get their own group in the model menu. Tap the star to keep one for everyday use.")
                }
                Section {
                    Button { showBrowser = true } label: { Label("Add a model…", systemImage: "plus") }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "checkmark") }
                }
            }
            .sheet(isPresented: $showBrowser) {
                // Picking adds the model; the browser's own stars work too.
                ModelBrowserView(onPick: { id in
                    if !settings.favoriteModelIDs.contains(id) { settings.toggleFavorite(id) }
                }, selectedID: "")
            }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func row(_ id: String) -> some View {
        let model = catalog.model(id)
        let trial = settings.isTrial(id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(catalog.displayName(id)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if id == settings.defaultModelID {
                        Text("DEFAULT")
                            .font(.readout(.caption2, weight: .semibold))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: Capsule())
                    }
                }
                if let model {
                    Text(model.providerName)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Button {
                withAnimation(Motion.smooth) { settings.setTrial(id, !trial) }
                Haptics.selection()
            } label: {
                Image(systemName: trial ? "star" : "flask")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trial ? "Move to Favorites" : "Move to Trying out")
        }
        .listRowBackground(Color.white.opacity(0.03))
    }

    /// Reorders one group; the stored list keeps everyday favorites ahead of the ones being tried.
    private func move(in group: [String], from source: IndexSet, to destination: Int, trying: Bool) {
        var reordered = group
        reordered.move(fromOffsets: source, toOffset: destination)
        settings.favoriteModelIDs = trying ? everyday + reordered : reordered + self.trying
        Haptics.selection()
    }

    private func remove(_ group: [String], at offsets: IndexSet) {
        for id in offsets.map({ group[$0] }) { settings.toggleFavorite(id) }
        Haptics.tap()
    }
}

/// Shown once after signing in: a short list of good models to start with instead of all of them.
struct StarterModelsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss
    @State private var picks: [ModelRanking.Pick] = []
    @State private var chosen: Set<String> = []

    /// The default for new chats: the best value pick if you kept it, else the first you kept.
    private var defaultID: String? {
        let kept = picks.filter { chosen.contains($0.id) }
        return (kept.first { $0.reasons.contains(.value) } ?? kept.first)?.id
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if picks.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                    }
                    ForEach(picks) { pick in
                        let on = chosen.contains(pick.id)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                PickReasons(reasons: pick.reasons)
                                HStack(spacing: 6) {
                                    Text(pick.model.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if pick.id == defaultID {
                                        Text("DEFAULT")
                                            .font(.readout(.caption2, weight: .semibold))
                                            .foregroundStyle(Theme.onAccent)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.accent, in: Capsule())
                                    }
                                }
                                Text(pick.model.providerName)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if on { chosen.remove(pick.id) } else { chosen.insert(pick.id) }
                            Haptics.selection()
                        }
                        .listRowBackground(Color.white.opacity(0.03))
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pick your models")
                            .font(.system(size: 28, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Halo can use any of \(catalog.models.count) models. These are good places to start; you can browse the rest any time.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .textCase(nil)
                    .padding(.bottom, 12)
                } footer: {
                    Text("The ones you keep become your favorites in the model menu.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .safeAreaInset(edge: .bottom) {
                Button(action: finish) {
                    Text("Continue")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty)
                .opacity(chosen.isEmpty ? 0.5 : 1)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { dismiss() }
                }
            }
            .task { await load() }
            .onChange(of: catalog.models.count) { _, _ in Task { await load() } }
        }
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
    }

    private func load() async {
        guard picks.isEmpty else { return }
        if catalog.models.isEmpty { await catalog.refreshIfNeeded() }
        let found = ModelRanking.topPicks(catalog.models)
        guard !found.isEmpty else { return }
        withAnimation(Motion.smooth) {
            picks = found
            chosen = Set(found.map(\.id))
        }
    }

    private func finish() {
        let kept = picks.map(\.id).filter { chosen.contains($0) }
        settings.favoriteModelIDs = kept
        settings.trialModelIDs = []
        if let defaultID {
            settings.defaultModelID = defaultID
            // The new chat waiting on screen was set up with the old default.
            if app.currentConversation == nil { app.draft.modelID = defaultID }
        }
        Haptics.success()
        dismiss()
    }
}
