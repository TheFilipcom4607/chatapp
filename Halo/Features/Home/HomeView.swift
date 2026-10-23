import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @State private var appeared = false

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part: String
        switch hour {
        case 5..<12: part = "Good morning"
        case 12..<17: part = "Good afternoon"
        case 17..<22: part = "Good evening"
        default: part = "Hello"
        }
        return "\(part), \(settings.userName)"
    }

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.55)
            ScrollView {
                VStack(spacing: 26) {
                    Spacer(minLength: 40)
                    GlowOrb(size: 120)
                        .scaleEffect(appeared ? 1 : 0.7)
                        .opacity(appeared ? 1 : 0)
                    VStack(spacing: 8) {
                        AuroraText(text: greeting, font: .system(size: 34, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text("What shall we create today?")
                            .font(.title3)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)

                    PersonaStrip()
                        .opacity(appeared ? 1 : 0)

                    QuickActions()
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { appeared = true } }
    }
}

struct PersonaStrip: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let personas = app.personas
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(personas) { p in
                    let selected = app.draft.personaID == p.id
                    Button {
                        withAnimation(Motion.snappy) { app.resetDraft(persona: p) }
                        Haptics.selection()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: p.icon).foregroundStyle(Color(hex: p.colorHex))
                            Text(p.name).foregroundStyle(selected ? Color.white : Theme.textSecondary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(selected ? .regular.tint(Color(hex: p.colorHex).opacity(0.35)).interactive() : .regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { app.sheet = .personaEditor(p.id) } label: { Label("Edit", systemImage: "pencil") }
                    }
                }
                Button { app.sheet = .personaEditor(nil) } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }
}

struct QuickActions: View {
    @Environment(AppModel.self) private var app

    private struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
        let colors: [Color]
        let run: (AppModel) -> Void
    }

    private var actions: [Action] {
        [
            Action(icon: "photo.on.rectangle.angled", title: "Create an image", subtitle: "Any style, any idea", colors: [Theme.pink, Theme.violet]) { app in
                app.requestComposer(prefill: "Create an image of ")
            },
            Action(icon: "chevron.left.forwardslash.chevron.right", title: "Write code", subtitle: "Build, run & preview", colors: [Theme.teal, Theme.indigo]) { app in
                if let coder = app.personas.first(where: { $0.name == "Coder" }) { app.resetDraft(persona: coder) }
                app.requestComposer(prefill: "")
            },
            Action(icon: "globe", title: "Search the web", subtitle: "Fresh, cited answers", colors: [Theme.indigo, Theme.teal]) { app in
                app.draft.webSearch = true
                app.requestComposer(prefill: "Search the web: ")
            },
            Action(icon: "waveform", title: "Make it speak", subtitle: "Natural voices", colors: [Theme.violet, Theme.teal]) { app in
                app.requestComposer(prefill: "Say this out loud in a warm voice: ")
            },
        ]
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(actions) { action in
                Button {
                    Haptics.tap()
                    action.run(app)
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: action.icon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(LinearGradient(colors: action.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                            Text(action.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(cornerRadius: 22, interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
