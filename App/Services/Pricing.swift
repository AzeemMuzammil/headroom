import Foundation

/// Anthropic API list prices (USD per million tokens), used to show an "API-equivalent value"
/// for Claude Code activity. On a Pro/Max plan this is not what you pay — it's what the same
/// tokens would cost on the API.
enum Pricing {
    struct Price {
        var input: Double
        var output: Double
        var cacheRead: Double? = nil   // defaults to 10% of input

        var cacheWrite5m: Double { input * 1.25 }
        var cacheWrite1h: Double { input * 2 }
        var read: Double { cacheRead ?? input * 0.1 }
    }

    // Most specific prefixes first.
    private static let table: [(prefix: String, price: Price)] = [
        ("claude-fable-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable", Price(input: 10, output: 50)),
        ("claude-mythos-5-1", Price(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos", Price(input: 10, output: 50)),
        ("claude-opus-5-5", Price(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", Price(input: 5, output: 25)),
        ("claude-opus-4-8", Price(input: 5, output: 25)),
        ("claude-opus-4-7", Price(input: 5, output: 25)),
        ("claude-opus-4-6", Price(input: 5, output: 25)),
        ("claude-opus-4-5", Price(input: 5, output: 25)),
        ("claude-opus-4", Price(input: 15, output: 75)),      // Opus 4 / 4.1
        ("claude-sonnet-5", Price(input: 2, output: 10)),
        ("claude-sonnet-4", Price(input: 3, output: 15)),
        ("claude-3-7-sonnet", Price(input: 3, output: 15)),
        ("claude-haiku-4-5", Price(input: 1, output: 5)),
        ("claude-3-5-haiku", Price(input: 0.8, output: 4)),
    ]
    private static let fallback = Price(input: 5, output: 25)

    static func price(for model: String) -> Price {
        // Bedrock / Vertex ids carry a prefix, e.g. "us.anthropic.claude-sonnet-4-5-…".
        let id = model.range(of: "claude-").map { String(model[$0.lowerBound...]) } ?? model
        return table.first { id.hasPrefix($0.prefix) }?.price ?? fallback
    }

    static func cost(model: String, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, fast: Bool) -> Double {
        let p = price(for: model)
        let perMillion = Double(input) * p.input
            + Double(output) * p.output
            + Double(cacheWrite5m) * p.cacheWrite5m
            + Double(cacheWrite1h) * p.cacheWrite1h
            + Double(cacheRead) * p.read
        return perMillion / 1_000_000 * (fast ? 2 : 1)
    }

    /// What those cache reads would have cost at the full input price, minus what they did cost.
    static func cacheSavings(model: String, cacheRead: Int, fast: Bool) -> Double {
        let p = price(for: model)
        return Double(cacheRead) * (p.input - p.read) / 1_000_000 * (fast ? 2 : 1)
    }
}
