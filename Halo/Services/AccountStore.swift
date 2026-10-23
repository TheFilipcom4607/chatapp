import Foundation
import Observation

/// Live credit / spend info from OpenRouter.
@MainActor
@Observable
final class AccountStore {
    private(set) var keyInfo: KeyInfo?
    private(set) var credits: CreditsInfo?
    private(set) var creditsError: String?
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false

    private let client: OpenRouterClient
    init(client: OpenRouterClient) { self.client = client }

    /// Best available "money left" number.
    var balance: Double? {
        if let credits { return credits.balance }
        return keyInfo?.limitRemaining
    }

    var balanceLabel: String {
        if credits != nil { return "Balance" }
        if keyInfo?.limitRemaining != nil { return "Key limit left" }
        return "Spent this month"
    }

    var headline: String {
        if let b = balance { return Money.format(b, compact: true) }
        if let m = keyInfo?.usageMonthly { return Money.format(m, compact: true) }
        return "–"
    }

    func refresh() async {
        guard KeyStore.shared.apiKey != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if let info = try? await client.keyInfo() { keyInfo = info }
        if let mk = KeyStore.shared.managementKey, !mk.isEmpty {
            do {
                credits = try await client.credits(managementKey: mk)
                creditsError = nil
            } catch {
                creditsError = error.localizedDescription
            }
        } else {
            credits = nil
        }
        lastUpdated = .now
    }

    func clear() {
        keyInfo = nil
        credits = nil
    }
}
