import SwiftUI

/// Switches each kind of tool on or off for every chat. A persona's own list still applies on top.
struct ToolsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                ForEach(ToolCapability.allCases) { cap in
                    Toggle(isOn: Binding(get: { settings.isToolEnabled(cap) }, set: { settings.setTool(cap, enabled: $0) })) {
                        HStack(spacing: 12) {
                            Image(systemName: cap.icon)
                                .font(.body)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cap.label)
                                Text(cap.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("Location, Calendar and Reminders ask for iOS permission the first time a model uses them. Adding events and reminders always waits for your OK.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
    }
}
