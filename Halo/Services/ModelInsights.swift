import Foundation

/// What the model detail page says about a model beyond its own listing: where its scores rank,
/// which benchmarks to show and how, and which models are worth considering instead.
enum ModelInsights {
    struct Benchmark: Identifiable, Hashable {
        /// Artificial Analysis's key, as in `ModelCatalog.benchmarks(for:)`.
        let key: String
        let title: String
        /// What it tests, in a few words.
        let detail: String
        var id: String { key }
    }

    struct BenchmarkGroup: Identifiable {
        let title: String
        let benchmarks: [Benchmark]
        var id: String { title }
    }

    static let mathIndex = "artificial_analysis_math_index"

    /// The benchmarks behind AA's indexes, in plain-language groups. AA retires benchmarks as models
    /// saturate them, so the newest models skip some (GPQA, LiveCodeBench) and older ones the new.
    static let groups: [BenchmarkGroup] = [
        BenchmarkGroup(title: "Reasoning and knowledge", benchmarks: [
            Benchmark(key: "hle", title: "Humanity's Last Exam", detail: "Expert questions in every field"),
            Benchmark(key: "gpqa", title: "GPQA Diamond", detail: "Graduate-level science"),
            Benchmark(key: "mmlu_pro", title: "MMLU-Pro", detail: "Broad knowledge"),
            Benchmark(key: "critpt", title: "CritPt", detail: "Research-level physics"),
            Benchmark(key: "aa_omniscience_accuracy", title: "Omniscience", detail: "Knows obscure facts"),
        ]),
        BenchmarkGroup(title: "Coding", benchmarks: [
            Benchmark(key: "terminalbench_v4_0", title: "Terminal-Bench 4", detail: "Real jobs in a terminal"),
            Benchmark(key: "terminalbench_v2_1", title: "Terminal-Bench 2.1", detail: "Real jobs in a terminal"),
            Benchmark(key: "terminalbench_hard", title: "Terminal-Bench Hard", detail: "The hardest terminal jobs"),
            Benchmark(key: "scicode", title: "SciCode", detail: "Scientific programming"),
            Benchmark(key: "livecodebench", title: "LiveCodeBench", detail: "Competitive programming"),
        ]),
        BenchmarkGroup(title: "Agents and work", benchmarks: [
            Benchmark(key: "gdpval_aa", title: "GDPval", detail: "Office work, judged against experts"),
            Benchmark(key: "tau2", title: "τ²-Bench", detail: "Support agent with tools"),
            Benchmark(key: "tau_banking", title: "τ²-Bench Banking", detail: "Banking agent with tools"),
        ]),
        BenchmarkGroup(title: "Reliability", benchmarks: [
            Benchmark(key: "ifbench", title: "IFBench", detail: "Follows exact instructions"),
            Benchmark(key: "lcr", title: "Long context", detail: "Reasons over long documents"),
            Benchmark(key: "aa_omniscience_non_hallucination_rate", title: "Avoids hallucinating", detail: "Says so when it doesn't know"),
        ]),
        BenchmarkGroup(title: "Math", benchmarks: [
            Benchmark(key: "aime_25", title: "AIME 2025", detail: "Competition math"),
            Benchmark(key: "aime", title: "AIME 2024", detail: "Competition math"),
            Benchmark(key: "math_500", title: "MATH-500", detail: "School to olympiad math"),
        ]),
    ]

    /// "85%" for a benchmark, "63" for an index.
    static func format(_ value: Double, key: String) -> String {
        key.hasSuffix("_index") ? EffortMenu.score(value) : "\(Int((value * 100).rounded()))%"
    }

    /// The models to rank and compare against: ones you'd chat with on purpose, once each. Variants
    /// sharing a canonical slug (":free", dated aliases) share their scores, so they'd count twice.
    static func peers(_ catalog: [ORModel]) -> [ORModel] {
        var seen: Set<String> = []
        return catalog.filter { ModelRanking.isChatPick($0) && seen.insert($0.canonicalSlug ?? $0.id).inserted }
    }

    /// 1 for the best, and how many were scored; ties share the better rank.
    static func rank(_ value: Double, among values: [Double]) -> (rank: Int, of: Int) {
        (values.filter { $0 > value }.count + 1, values.count)
    }

    /// The 3:1 blended price per million tokens, 0 when free; nil when unknown.
    static func price(_ model: ORModel) -> Double? {
        model.isFree ? 0 : ModelRanking.blendedPrice(model)
    }

    struct Alternative: Identifiable, Hashable {
        enum Kind: Hashable {
            case smarter, cheaper, faster
            var title: String {
                switch self {
                case .smarter: return "Smarter for the price"
                case .cheaper: return "Nearly as smart, for less"
                case .faster: return "Faster, nearly as smart"
                }
            }
            var icon: String {
                switch self {
                case .smarter: return "brain.head.profile"
                case .cheaper: return "dollarsign.circle"
                case .faster: return "hare"
                }
            }
        }
        let kind: Kind
        let model: ORModel
        /// "+6 IQ, similar price".
        let detail: String
        var id: String { model.id }
    }

    /// How close in intelligence counts as "nearly as smart": a couple of points is within the noise
    /// of AA's index.
    static let closeEnough = 2.0

    /// Up to three models worth a look instead: the smartest for about the same price, the cheapest
    /// that's nearly as smart, and the fastest that's nearly as smart and not much pricier. Each is
    /// listed once. `speed` is tokens per second, measured the same way for every model.
    static func alternatives(to model: ORModel, among catalog: [ORModel], speed: (ORModel) -> Double?) -> [Alternative] {
        guard let iq = model.intelligence, let cost = price(model) else { return [] }
        let mine = model.canonicalSlug ?? model.id
        let rated: [(model: ORModel, iq: Double, cost: Double)] = peers(catalog).compactMap { m in
            guard (m.canonicalSlug ?? m.id) != mine, let i = m.intelligence, let p = price(m) else { return nil }
            return (m, i, p)
        }
        var result: [Alternative] = []
        func taken(_ m: ORModel) -> Bool { result.contains { $0.model.id == m.id } }

        if let s = rated.filter({ $0.iq >= iq + closeEnough && $0.cost <= cost * 1.1 })
            .max(by: { ($0.iq, -$0.cost) < ($1.iq, -$1.cost) }) {
            result.append(Alternative(kind: .smarter, model: s.model, detail: "\(iqDelta(s.iq - iq)), \(priceCompare(s.cost, cost))"))
        }
        if cost > 0, let c = rated.filter({ $0.iq >= iq - closeEnough && $0.cost <= cost / 1.5 && !taken($0.model) })
            .min(by: { ($0.cost, -$0.iq) < ($1.cost, -$1.iq) }) {
            result.append(Alternative(kind: .cheaper, model: c.model, detail: "\(iqDelta(c.iq - iq)), \(priceCompare(c.cost, cost))"))
        }
        if let tps = speed(model), tps > 0 {
            var fastest: (model: ORModel, iq: Double, tps: Double)?
            for r in rated where r.iq >= iq - closeEnough && r.cost <= max(cost * 1.5, 0.01) && !taken(r.model) {
                guard let s = speed(r.model), s >= tps * 1.5, s > fastest?.tps ?? 0 else { continue }
                fastest = (r.model, r.iq, s)
            }
            if let f = fastest {
                result.append(Alternative(kind: .faster, model: f.model, detail: "\(times(f.tps / tps)) faster, \(iqDelta(f.iq - iq))"))
            }
        }
        return result
    }

    /// "+6 IQ", "−2 IQ", "same IQ".
    static func iqDelta(_ d: Double) -> String {
        let n = Int(d.rounded())
        return n == 0 ? "same IQ" : n > 0 ? "+\(n) IQ" : "−\(-n) IQ"
    }

    /// The other model's price next to this one's: "4× cheaper", "free", "similar price".
    static func priceCompare(_ other: Double, _ mine: Double) -> String {
        if other == 0 { return mine == 0 ? "also free" : "free" }
        if other <= mine / 1.5 { return "\(times(mine / other)) cheaper" }
        if other >= mine * 1.5 { return "\(times(other / mine)) the price" }
        return "similar price"
    }

    /// "1.6×" under 3, then whole: "4×", "12×".
    static func times(_ x: Double) -> String {
        x < 3 ? "\(x.formatted(.number.precision(.fractionLength(0...1))))×" : "\(Int(x.rounded()))×"
    }
}
