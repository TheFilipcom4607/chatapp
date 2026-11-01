import SwiftUI

/// The user's own system prompt.
struct SystemPromptSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppModel.self) private var app
    @Environment(ModelCatalog.self) private var catalog
    @State private var confirmLoad = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextEditor(text: $settings.customSystemPrompt)
                    .font(.callout.monospaced())
                    .frame(minHeight: 260)
            } footer: {
                Text("Sent with every chat, after the persona's prompt and Halo's own instructions.")
            }
            Section {
                Toggle("Replace Halo's prompt", isOn: $settings.replaceSystemPrompt)
                Button("Start from Halo's prompt") {
                    if settings.customSystemPrompt.isEmpty { loadDefault() } else { confirmLoad = true }
                }
            } footer: {
                Text("When on, this text is the whole system prompt: no persona, date, formatting or tool notes unless they're in it. Tools still work. \"Start from Halo's prompt\" puts Halo's own prompt here to edit, as sent for a new chat with your default model and persona; {{date}} and {{model}} are filled in on each request.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .confirmationDialog("Replace your text with Halo's prompt?", isPresented: $confirmLoad, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { loadDefault() }
        }
        .navigationTitle("System prompt")
        .macSheetBar("System prompt", back: true)
        .inlineNavigationTitle()
    }
}

extension SystemPromptSettingsView {
    private func loadDefault() {
        let persona = app.persona(id: settings.defaultPersonaID.flatMap(UUID.init(uuidString:)))
        settings.customSystemPrompt = RequestBuilder.defaultPromptTemplate(settings: settings, catalog: catalog, persona: persona)
        settings.replaceSystemPrompt = true
    }
}

/// Tools the user defines as curl commands.
struct CustomToolsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                ForEach($settings.customTools) { $tool in
                    NavigationLink {
                        CustomToolEditor(tool: $tool)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.name.isEmpty ? "Untitled" : tool.name)
                                Text(tool.curl).font(.caption.monospaced()).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            }
                            Spacer()
                            if !tool.enabled { Text("Off").font(.caption).foregroundStyle(Theme.textTertiary) }
                        }
                    }
                }
                .onDelete { settings.customTools.remove(atOffsets: $0) }
                Button {
                    settings.customTools.append(CustomTool(name: "new_tool", curl: "curl https://example.com/api?q={{query}}"))
                } label: { Label("Add tool", systemImage: "plus") }
            } footer: {
                Text("Each tool is a curl command the model can call. Write {{name}} where a parameter goes. The reply's status and body go back to the model. Swipe or open a tool to delete it.")
                    .wrapsInList()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Custom tools")
        .macSheetBar("Custom tools", back: true)
        .inlineNavigationTitle()
    }
}

struct CustomToolEditor: View {
    @Binding var tool: CustomTool
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var testArgs = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section {
                Toggle("On", isOn: $tool.enabled)
                TextField("Name (e.g. get_stock_price)", text: $tool.name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if tool.functionName != tool.name, !tool.name.isEmpty {
                    Text("The model sees it as \(tool.functionName)").font(.caption).foregroundStyle(Theme.textTertiary)
                }
                TextField("What it does, for the model", text: $tool.description, axis: .vertical)
                    .lineLimit(2...6)
            } header: { Text("Tool") }
            Section {
                TextEditor(text: $tool.parameters)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 80)
            } header: { Text("Parameters") } footer: {
                Text("One per line: name: what it is. For example\nsymbol: stock ticker like AAPL")
            }
            Section {
                TextEditor(text: $tool.curl)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 140)
            } header: { Text("curl command") } footer: {
                Text("Supports -X, -H, -d / --data, --data-urlencode, --json, -u, -A, -G. Example:\ncurl -H \"Authorization: Bearer KEY\" \"https://api.example.com/quote?symbol={{symbol}}\"")
            }
            Section {
                TextField("Test values: name=value, one per line", text: $testArgs, axis: .vertical)
                    .lineLimit(1...6)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(testing ? "Running…" : "Run test") { Task { await test() } }
                    .disabled(testing || !tool.isValid)
                if let testResult {
                    Text(testResult)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(40)
                }
            } header: { Text("Test") }
            Section {
                Button("Delete tool", role: .destructive) {
                    let id = tool.id
                    dismiss()
                    // After the screen has gone: its binding into the list would point past the end.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settings.customTools.removeAll { $0.id == id } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(tool.name.isEmpty ? "Tool" : tool.name)
        .macSheetBar(tool.name.isEmpty ? "Tool" : tool.name, back: true)
        .inlineNavigationTitle()
    }

    private func test() async {
        testing = true
        var args: [String: JSONValue] = [:]
        for line in testArgs.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard let key = parts.first?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { continue }
            args[key] = .string(parts.count > 1 ? String(parts[1]) : "")
        }
        let outcome = await CustomToolRunner.run(tool, args: .object(args))
        testResult = outcome.text
        testing = false
    }
}
