import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(ModelCatalog.self) private var catalog
    @Environment(AccountStore.self) private var account
    @Environment(AppLock.self) private var lock
    @Environment(\.dismiss) private var dismiss
    @State private var managementKey = KeyStore.shared.managementKey ?? ""
    @State private var apiKeyDraft = ""
    @State private var showDefaultModelPicker = false
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var confirmDeleteAll = false
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenRouter").font(.headline)
                            Text(account.keyInfo?.label ?? "Connected").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(account.headline).font(.readout(.headline, weight: .semibold))
                            Text(account.balanceLabel).font(.caption2).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    SecureField("Management key (optional, for true balance)", text: $managementKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveManagementKey)
                    if !managementKey.isEmpty && managementKey != (KeyStore.shared.managementKey ?? "") {
                        Button("Save management key", action: saveManagementKey)
                    }
                    if let err = account.creditsError {
                        Text(err).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        SecureField("Replace API key", text: $apiKeyDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !apiKeyDraft.isEmpty {
                            Button("Save") { app.setAPIKey(apiKeyDraft); apiKeyDraft = ""; Haptics.success() }
                        }
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                } header: {
                    Text("Account")
                } footer: {
                    Text("A management key (openrouter.ai/settings/management-keys) lets Halo show your full account balance. Without it Halo shows this key's spend and limit.")
                }

                Section("You") {
                    TextField("Your name", text: $settings.userName)
                }

                Section("Models") {
                    Button {
                        showDefaultModelPicker = true
                    } label: {
                        LabeledContent("Default chat model", value: catalog.displayName(settings.defaultModelID))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    Picker("Image model", selection: $settings.imageModelID) {
                        ForEach(catalog.imageModels) { Text($0.shortName).tag($0.id) }
                        if catalog.imageModel(settings.imageModelID) == nil { Text(catalog.displayName(settings.imageModelID)).tag(settings.imageModelID) }
                    }
                    Picker("Video model", selection: $settings.videoModelID) {
                        ForEach(catalog.videoModels) { Text($0.shortName).tag($0.id) }
                        if catalog.videoModel(settings.videoModelID) == nil { Text(catalog.displayName(settings.videoModelID)).tag(settings.videoModelID) }
                    }
                    Picker("Voice model", selection: $settings.speechModelID) {
                        ForEach(catalog.speechModels) { Text($0.shortName).tag($0.id) }
                        if catalog.speechModel(settings.speechModelID) == nil { Text(catalog.displayName(settings.speechModelID)).tag(settings.speechModelID) }
                    }
                    let voices = catalog.speechModel(settings.speechModelID)?.supportedVoices ?? []
                    if !voices.isEmpty {
                        Picker("Voice", selection: $settings.speechVoice) {
                            ForEach(voices, id: \.self) { Text($0).tag($0) }
                            if !voices.contains(settings.speechVoice) { Text(settings.speechVoice).tag(settings.speechVoice) }
                        }
                    } else {
                        TextField("Voice", text: $settings.speechVoice)
                    }
                }

                Section {
                    Toggle("Smooth streaming", isOn: $settings.smoothStreaming)
                    Toggle("Haptics", isOn: $settings.haptics)
                    Toggle("Notify when replies finish in background", isOn: $settings.notifyWhenDone)
                    Toggle("Prompt caching (Claude)", isOn: $settings.promptCaching)
                    Picker("Long chats", selection: $settings.longChatMode) {
                        ForEach(LongChatMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("PDF reading", selection: $settings.pdfEngine) {
                        Text("Automatic").tag("auto")
                        Text("Free text extraction").tag("cloudflare-ai")
                        Text("OCR (scans, $2/1k pages)").tag("mistral-ocr")
                        Text("Model native").tag("native")
                    }
                } header: {
                    Text("Behavior")
                } footer: {
                    Text("Caching makes long Claude chats much cheaper. Gemini, OpenAI, DeepSeek and Grok cache automatically. When a chat nears the model's limit, Halo can warn you, summarize older messages for you, or let OpenRouter drop messages from the middle.")
                }

                Section {
                    Toggle("Require \(lock.methodName)", isOn: Binding(
                        get: { settings.appLock },
                        set: { $0 ? lock.enable() : lock.disable() }
                    ))
                    .disabled(!settings.appLock && !lock.isAvailable)
                    if settings.appLock {
                        Picker("Lock", selection: $settings.appLockDelay) {
                            Text("Immediately").tag(0)
                            Text("After 1 minute").tag(60)
                            Text("After 5 minutes").tag(300)
                            Text("After 15 minutes").tag(900)
                        }
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    if lock.isAvailable {
                        Text("Halo asks for \(lock.methodName) when you come back to it, and hides your chats in the app switcher. Your device passcode always works too.")
                    } else {
                        Text("Set a passcode on this device to lock Halo.")
                    }
                }

                Section("Personas") {
                    ForEach(app.personas) { p in
                        Button { app.sheet = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { app.sheet = .personaEditor(p.id) } } label: {
                            Label { Text(p.name).foregroundStyle(Theme.textPrimary) } icon: { Image(systemName: p.icon).foregroundStyle(Theme.textSecondary) }
                        }
                    }
                }

                Section("Data") {
                    Button {
                        exportURL = try? ExportService.exportAll(context: app.context)
                    } label: { Label("Export all chats (JSON)", systemImage: "square.and.arrow.up") }
                    Button { showImporter = true } label: { Label("Import backup or OpenRouter chat", systemImage: "square.and.arrow.down") }
                    Button("Delete all chats", role: .destructive) { confirmDeleteAll = true }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Link("OpenRouter dashboard", destination: URL(string: "https://openrouter.ai/activity")!)
                    Link("Buy credits", destination: URL(string: "https://openrouter.ai/settings/credits")!)
                } header: { Text("About") }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button { dismiss() } label: { Image(systemName: "xmark") } }
            }
            .sheet(isPresented: $showDefaultModelPicker) {
                ModelBrowserView(onPick: { settings.defaultModelID = $0 })
            }
            .sheet(item: Binding(get: { exportURL.map(ShareItem.init) }, set: { exportURL = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes) { result in
                // A JSON backup made by Halo, or a Markdown export from the chat page on openrouter.ai.
                if case .success(let url) = result { app.importFile(url) }
            }
            .confirmationDialog("Delete all chats?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    for c in (try? app.context.fetch(FetchDescriptor<Conversation>())) ?? [] { app.delete(c) }
                    Haptics.warning()
                }
            }
            .confirmationDialog("Sign out of OpenRouter?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { dismiss(); app.signOut() }
            }
            .task { await catalog.refreshMediaModels() }
        }
    }

    static let importTypes: [UTType] = ([UTType.json, UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md"), UTType.plainText] as [UTType?])
        .compactMap { $0 }

    private func saveManagementKey() {
        KeyStore.shared.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Haptics.success()
        Task { await account.refresh() }
    }
}

