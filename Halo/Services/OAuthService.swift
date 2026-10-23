import Foundation
import AuthenticationServices
import CryptoKit
import Network
import UIKit

/// "Sign in with OpenRouter" via OAuth PKCE.
/// OpenRouter documents https and localhost callbacks, so the app runs a tiny
/// loopback HTTP listener that receives `?code=` while the auth sheet is open.
@MainActor
final class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?

    enum OAuthError: LocalizedError {
        case cancelled, noCode, listenerFailed
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled."
            case .noCode: return "OpenRouter didn't return an authorization code."
            case .listenerFailed: return "Couldn't start the local sign-in listener. Paste a key instead."
            }
        }
    }

    func signIn() async throws -> String {
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)
        let port = try await startListener()
        let callback = "http://localhost:\(port)/callback"
        var comps = URLComponents(string: "https://openrouter.ai/auth")!
        comps.queryItems = [
            URLQueryItem(name: "callback_url", value: callback),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "key_label", value: "Halo (iPhone)"),
        ]
        defer { stopListener() }
        let code: String = try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "halo") { [weak self] url, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let url, let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value {
                        self.finish(.success(code))
                    } else if error != nil {
                        self.finish(.failure(OAuthError.cancelled))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
        return try await OpenRouterClient.exchangeOAuthCode(code: code, verifier: verifier)
    }

    private func finish(_ result: Result<String, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        session?.cancel()
        session = nil
        cont.resume(with: result)
    }

    // MARK: Loopback listener

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        let listener = try NWListener(using: params)
        self.listener = listener
        weak var weakSelf = self
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let code = URLComponents(string: "http://localhost\(path)")?.queryItems?.first { $0.name == "code" }?.value
                let html = """
                <html><head><meta name="viewport" content="width=device-width"><style>body{background:#000;color:#fff;font:17px -apple-system;display:flex;height:90vh;align-items:center;justify-content:center;text-align:center}</style></head>
                <body><div><h2>Signed in ✨</h2><p>You can return to Halo.</p></div></body></html>
                """
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                if let code {
                    DispatchQueue.main.async { MainActor.assumeIsolated { weakSelf?.finish(.success(code)) } }
                }
            }
        }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed:
                    once.done = true
                    cont.resume(throwing: OAuthError.listenerFailed)
                default: break
                }
            }
            listener.start(queue: .main)
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    // MARK: PKCE

    static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
            return ASPresentationAnchor(windowScene: scenes.first!)
        }
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
