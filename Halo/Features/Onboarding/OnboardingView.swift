import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @State private var pastedKey = ""
    @State private var showPaste = false
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var oauth = OAuthService()
    @State private var appeared = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.9)
            VStack(spacing: 28) {
                Spacer()
                GlowOrb(size: 170, active: isSigningIn)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 10) {
                    AuroraText(text: "Halo", font: .system(size: 52, weight: .bold, design: .rounded))
                    Text("Every frontier model. One beautiful app.")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                Spacer()
                VStack(spacing: 14) {
                    Button {
                        signIn()
                    } label: {
                        HStack(spacing: 10) {
                            if isSigningIn { ProgressView().tint(.white) } else { Image(systemName: "person.badge.key.fill") }
                            Text("Sign in with OpenRouter").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.indigo)
                    .controlSize(.large)
                    .disabled(isSigningIn)

                    if showPaste {
                        HStack(spacing: 10) {
                            SecureField("sk-or-v1-…", text: $pastedKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                            Button("Save") {
                                guard pastedKey.hasPrefix("sk-") else { error = "That doesn't look like an OpenRouter key."; return }
                                Haptics.success()
                                app.setAPIKey(pastedKey)
                            }
                            .buttonStyle(.glass)
                            .disabled(pastedKey.isEmpty)
                        }
                        .padding(14)
                        .glassCard(cornerRadius: 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Button("Paste an API key instead") {
                            withAnimation(Motion.smooth) { showPaste = true }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red.opacity(0.9)).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.75).delay(0.1)) { appeared = true } }
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
