import SwiftUI

struct PersonaEditorView: View {
    let personaID: UUID?
    /// Pushed inside another navigation stack (Settings): Back cancels, so there's no Cancel button.
    var pushed = false
    @Environment(AppModel.self) private var app
    @Environment(ModelCatalog.self) private var catalog
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = "bubble.left"
    @State private var color = "#8B7CF6"
    @State private var prompt = ""
    @State private var modelID: String?
    @State private var effort: String?
    @State private var caps: Set<ToolCapability> = Set(ToolCapability.allCases)
    @State private var searchMode: SearchMode = .auto
    @State private var searchDepth: SearchDepth = .standard
    @State private var searchEngine: SearchEngine?
    @State private var showModelPicker = false
    @State private var loaded = false

    private let icons = ["bubble.left", "chevron.left.forwardslash.chevron.right", "paintpalette", "magnifyingglass", "brain.head.profile",
                         "book", "graduationcap", "briefcase", "heart", "leaf", "globe", "music.note", "camera", "dumbbell", "fork.knife", "airplane"]
    private let colors = ["#8B7CF6", "#6366F1", "#2DD4BF", "#EC4899", "#F59E0B", "#22C55E", "#EF4444", "#38BDF8"]

    var body: some View {
        if pushed {
            form
        } else {
            NavigationStack { form }
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 50, height: 50)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    TextField("Name", text: $name).font(.title3.weight(.semibold))
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(icons, id: \.self) { i in
                            Image(systemName: i)
                                .frame(width: 36, height: 36)
                                .foregroundStyle(i == icon ? Theme.onAccent : Theme.textSecondary)
                                .background(i == icon ? Theme.accent : Theme.fill, in: Circle())
                                .onTapGesture { icon = i; Haptics.selection() }
                        }
                    }
                }
                .horizontalScrollFade()
            }

            Section("Instructions") {
                TextEditor(text: $prompt)
                    .frame(minHeight: 180)
                    .font(.callout)
            }

            Section("Model") {
                Button {
                    showModelPicker = true
                } label: {
                    LabeledContent("Model", value: modelID.map { catalog.displayName($0) } ?? "Use default")
                }
                .foregroundStyle(Theme.textPrimary)
                if modelID != nil { Button("Use default model") { modelID = nil } }
                Picker("Reasoning effort", selection: $effort) {
                    Text("Default").tag(String?.none)
                    ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text(EffortMenu.label($0)).tag(String?.some($0)) }
                }
            }

            Section("Tools") {
                ForEach(ToolCapability.allCases) { cap in
                    Toggle(isOn: Binding(get: { caps.contains(cap) }, set: { on in if on { caps.insert(cap) } else { caps.remove(cap) } })) {
                        Label(cap.label, systemImage: cap.icon)
                    }
                }
                if caps.contains(.search) {
                    Picker("Web search", selection: $searchMode) {
                        ForEach([SearchMode.auto, .always, .off]) { Text($0.title).tag($0) }
                    }
                    if searchMode != .off {
                        Picker("Search depth", selection: $searchDepth) {
                            ForEach(SearchDepth.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Search engine", selection: $searchEngine) {
                            Text("Default").tag(SearchEngine?.none)
                            ForEach(SearchEngine.allCases) { Text($0.title).tag(SearchEngine?.some($0)) }
                        }
                    }
                }
            }

            if let personaID, let p = app.persona(id: personaID), !p.isBuiltin || app.personas.count > 1 {
                Section {
                    Button("Delete persona", role: .destructive) {
                        app.context.delete(p)
                        try? app.context.save()
                        dismiss()
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(personaID == nil ? "New persona" : "Edit persona")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !pushed {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }.fontWeight(.semibold).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ModelBrowserView(onPick: { modelID = $0 })
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let personaID, let p = app.persona(id: personaID) else {
            prompt = "You are a helpful assistant."
            return
        }
        name = p.name
        icon = p.icon
        color = p.colorHex
        prompt = p.systemPrompt
        modelID = p.modelID
        effort = p.reasoningEffort
        caps = p.capabilities
        searchMode = p.searchMode
        searchDepth = p.searchDepth
        searchEngine = p.searchEngine
    }

    private func save() {
        let p: Persona
        if let personaID, let existing = app.persona(id: personaID) {
            p = existing
        } else {
            p = Persona(name: name, icon: icon, colorHex: color, systemPrompt: prompt, modelID: modelID, reasoningEffort: effort,
                        capabilities: Array(caps), alwaysSearch: searchMode == .always, isBuiltin: false, sortIndex: app.personas.count)
            app.context.insert(p)
        }
        p.name = name
        p.icon = icon
        p.colorHex = color
        p.systemPrompt = prompt
        p.modelID = modelID
        p.reasoningEffort = effort
        p.capabilities = caps
        p.searchMode = searchMode
        p.searchDepth = searchDepth
        p.searchEngine = searchEngine
        try? app.context.save()
        Haptics.success()
        dismiss()
    }
}
