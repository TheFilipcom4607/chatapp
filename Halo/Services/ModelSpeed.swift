import Foundation
import SwiftData

/// How fast a model has been for you: medians over your own streamed replies, so the numbers
/// reflect your network and the providers you actually got. Only streamed replies record a
/// time to first token, so background replies drop out on their own.
struct ModelSpeed: Hashable, Sendable {
    var tokensPerSecond: Double
    var timeToFirstToken: Double
    var replies: Int

    struct Sample: Sendable {
        var modelID: String
        var latency: Double
        var duration: Double
        var outputTokens: Int
    }

    /// Replies under 20 tokens are left out: fixed overhead swamps their speed.
    static func medians(_ samples: [Sample]) -> [String: ModelSpeed] {
        let timed = samples.filter { $0.outputTokens >= 20 && $0.duration - $0.latency > 0.05 }
        return Dictionary(grouping: timed, by: \.modelID).mapValues { s in
            ModelSpeed(tokensPerSecond: median(s.map { Double($0.outputTokens) / ($0.duration - $0.latency) }),
                       timeToFirstToken: median(s.map(\.latency)),
                       replies: s.count)
        }
    }

    @MainActor
    static func load(from context: ModelContext) -> [String: ModelSpeed] {
        let assistant = MessageRole.assistant.rawValue
        let complete = MessageStatus.complete.rawValue
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate {
            $0.roleRaw == assistant && $0.statusRaw == complete && $0.latency != nil && $0.duration != nil
        })
        let messages = (try? context.fetch(descriptor)) ?? []
        return medians(messages.compactMap { m in
            guard let id = m.modelID, let latency = m.latency, let duration = m.duration,
                  let out = answerTokens(m) else { return nil }
            return Sample(modelID: id, latency: latency, duration: duration, outputTokens: out)
        })
    }

    /// The tokens written after the first word of the answer, the stretch `duration - latency` times.
    /// Reasoning comes before that, so it's taken out; when a model thought but didn't report how
    /// many tokens that took, the split is unknown and there's no honest speed (nil).
    static func answerTokens(_ m: Message) -> Int? {
        guard let usage = m.usage, let out = usage.completionTokens else { return nil }
        if usage.reasoningTokens == 0 && !m.reasoning.isEmpty { return nil }
        return max(0, out - usage.reasoningTokens)
    }

    /// One reply's answer speed, for its details.
    static func tokensPerSecond(_ m: Message) -> Double? {
        guard let latency = m.latency, let duration = m.duration, duration - latency > 0.05,
              let out = answerTokens(m) else { return nil }
        return Double(out) / (duration - latency)
    }

    /// "62 tok/s · 0.8s"
    var summary: String { "\(Int(tokensPerSecond.rounded())) tok/s · \(Self.seconds(timeToFirstToken))" }

    static func seconds(_ s: Double) -> String {
        s < 10 ? String(format: "%.1fs", s) : String(format: "%.0fs", s)
    }

    private static func median(_ values: [Double]) -> Double {
        let v = values.sorted()
        let mid = v.count / 2
        return v.count.isMultiple(of: 2) ? (v[mid - 1] + v[mid]) / 2 : v[mid]
    }
}
