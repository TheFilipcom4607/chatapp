import SwiftUI

/// Empty new-chat screen: one quiet line, the composer does the rest.
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("What can I help with?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if let persona = app.persona(id: app.draft.personaID), persona.name != "Halo" {
                Text(persona.name)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { hideKeyboard() }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
