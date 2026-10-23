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
                        SettingsValueRow(title: "Default chat model", value: catalog.displayName(settings.defaultModelID),
                                         systemImage: "chevron.right")
                    }
                    MediaModelMenu(kind: .image, selectedID: settings.imageModelID) { settings.imageModelID = $0 } label: {
                        SettingsValueRow(title: "Image model", value: catalog.mediaName(.image, settings.imageModelID))
                    }
                    MediaModelMenu(kind: .video, selectedID: settings.videoModelID) { settings.videoModelID = $0 } label: {
                        SettingsValueRow(title: "Video model", value: catalog.mediaName(.video, settings.videoModelID))
                    }
                    MediaModelMenu(kind: .speech, selectedID: settings.speechModelID) { id in
                        settings.speechModelID = id
                        // Voices differ per model: keep yours if the new one has it.
                        let voices = catalog.speechModel(id)?.supportedVoices ?? []
                        if !voices.isEmpty && !voices.contains(settings.speechVoice) { settings.speechVoice = voices[0] }
                    } label: {
                        SettingsValueRow(title: "Voice model", value: catalog.mediaName(.speech, settings.speechModelID))
                    }
                    let voices = catalog.speechModel(settings.speechModelID)?.supportedVoices ?? []
                    if !voices.isEmpty {
                        MenuPickerRow(title: "Voice", selection: $settings.speechVoice,
                                      options: options(voices.map { ($0, $0) }, current: settings.speechVoice))
                    } else {
                        // Fish Audio and Seed Audio have no named voices: directions in the text
                        // ("[nervous]", "(whispering)") shape how they sound.
                        LabeledContent("Voice", value: "Set by the model")
                    }
                }

                Section {
                    MenuPickerRow(title: "Default tier", selection: $settings.defaultServiceTier,
                                  options: ServiceTier.allCases.map { .init(id: $0.rawValue, name: $0.title) })
                } header: {
                    Text("Speed and price")
                } footer: {
                    Text("Some models are sold in tiers. Flex costs less but is slower and can fail when the provider is busy. Priority costs more and answers faster. Models without the tier run as Standard. Change it for one chat from the model menu at the top.")
                }

                Section {
                    Toggle("Smooth streaming", isOn: $settings.smoothStreaming)
                    Toggle("Haptics", isOn: $settings.haptics)
                    Toggle("Notify when replies finish in background", isOn: $settings.notifyWhenDone)
                    Toggle("Prompt caching (Claude)", isOn: $settings.promptCaching)
                    Toggle("Ask before shell commands", isOn: $settings.askBeforeShell)
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
                    Text("Caching makes long Claude chats much cheaper. Gemini, OpenAI, DeepSeek and Grok cache automatically. When a chat nears the model's limit, Halo can warn you, summarize older messages for you, or let OpenRouter drop messages from the middle. Shell commands can reach the internet, so Halo shows each one for you to allow first unless you turn that off.")
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
                ModelBrowserView(onPick: { settings.defaultModelID = $0 }, selectedID: settings.defaultModelID)
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

    /// The catalog's choices, plus the saved one if the catalog no longer lists it.
    private func options(_ list: [(String, String)], current: String) -> [MenuPickerRow.Option] {
        var result = list.map { MenuPickerRow.Option(id: $0.0, name: $0.1) }
        if !result.contains(where: { $0.id == current }) {
            result.append(.init(id: current, name: catalog.displayName(current)))
        }
        return result
    }

    private func saveManagementKey() {
        KeyStore.shared.managementKey = managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Haptics.success()
        Task { await account.refresh() }
    }
}


/// Title on the left, value on the right; the value stays on one line however long it is.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var systemImage = "chevron.up.chevron.down"

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
    }
}

/// A settings picker that opens a menu, laid out as a fixed one-line row (the system menu picker
/// wraps long values onto a second line).
struct MenuPickerRow: View {
    struct Option: Identifiable {
        let id: String
        let name: String
    }

    let title: String
    @Binding var selection: String
    let options: [Option]

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options) { Text($0.name).tag($0.id) }
            }
        } label: {
            SettingsValueRow(title: title, value: options.first { $0.id == selection }?.name ?? selection)
        }
    }
}
