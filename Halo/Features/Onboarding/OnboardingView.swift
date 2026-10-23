import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var pastedKey = ""
    @State private var showPaste = false
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var oauth = OAuthService()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                EclipseMark(size: 76)
                VStack(spacing: 8) {
                    Text("Halo")
                        .font(.system(size: 40, weight: .semibold))
                    Text("Chat with any model on OpenRouter.")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(spacing: 14) {
                Button(action: signIn) {
                    HStack(spacing: 8) {
                        if isSigningIn { ProgressView().tint(Theme.onAccent) }
                        Text("Continue with OpenRouter").fontWeight(.semibold)
                    }
                    .foregroundStyle(Theme.onAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSigningIn)

                if showPaste {
                    HStack(spacing: 10) {
                        SecureField("sk-or-v1-…", text: $pastedKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button("Save") {
                            let key = pastedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard key.hasPrefix("sk-") else { error = "That doesn't look like an OpenRouter key."; return }
                            Haptics.success()
                            app.setAPIKey(key)
                        }
                        .fontWeight(.semibold)
                        .disabled(pastedKey.isEmpty)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Button("Use an API key instead") {
                        withAnimation(Motion.smooth) { showPaste = true }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(height: 44)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.negative).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Theme.background)
    }

    private func signIn() {
        error = nil
        isSigningIn = true
        Task {
            do {
                let key = try await oauth.signIn()
                Haptics.success()
                app.setAPIKey(key)
            } catch {
                if case OAuthService.OAuthError.cancelled = error {} else { self.error = error.localizedDescription }
                withAnimation(Motion.smooth) { showPaste = true }
            }
            isSigningIn = false
        }
    }
}
