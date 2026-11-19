import Foundation

/// List prices in US dollars per million tokens.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double

    public init(input: Double, output: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }

    /// Writing to the prompt cache costs 1.25 times the input price.
    public var cacheWrite: Double { input * 1.25 }
}

/// Estimated API list prices for Claude models, matched by family and version.
public enum ModelPricing {
    /// Most specific keys first: the first key contained in the model id wins, so
    /// `opus-5-5` must come before `opus-5`.
    static let table: [(key: String, price: ModelPrice)] = [
        ("opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("opus-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-8", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-7", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-6", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-5", ModelPrice(input: 5, output: 25, cacheRead: 0.50)),
        ("opus-4-1", ModelPrice(input: 15, output: 75, cacheRead: 1.50)),
        ("opus-4", ModelPrice(input: 15, output: 75, cacheRead: 1.50)),
        ("sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.10)),
        ("sonnet-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("sonnet-4-6", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("sonnet-4-5", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("sonnet-4", ModelPrice(input: 3, output: 15, cacheRead: 0.30)),
        ("haiku-5-5", ModelPrice(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("haiku-4-5", ModelPrice(input: 1, output: 5, cacheRead: 0.10)),
        ("fable-5-2", ModelPrice(input: 8, output: 40, cacheRead: 0.20)),
        ("fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 1.00)),
        ("fable-5", ModelPrice(input: 10, output: 50, cacheRead: 1.00))
    ]

    /// The list price for a model id such as `claude-opus-4-5-20251101`, or nil when unknown.
    public static func price(for modelID: String) -> ModelPrice? {
        let id = modelID.lowercased()
        return table.first { id.contains($0.key) }?.price
    }

    /// Estimated cost in US dollars, or nil when the model has no known price.
    public static func cost(of usage: TokenUsage, model modelID: String) -> Double? {
        guard let price = price(for: modelID) else { return nil }
        let dollars = Double(usage.input) * price.input
            + Double(usage.output) * price.output
            + Double(usage.cacheWrite) * price.cacheWrite
            + Double(usage.cacheRead) * price.cacheRead
        return dollars / 1_000_000
    }
}
