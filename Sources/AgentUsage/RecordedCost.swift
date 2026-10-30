import Foundation

/// Local agent-reported USD, not a billing ledger. Invalid costs must not discard tokens.
struct RecordedUSD: Decodable {
    let value: Decimal?

    init(from decoder: any Decoder) {
        let amount = try? decoder.singleValueContainer().decode(Decimal.self)
        // Defensive bound, not a provider limit; also keeps period sums safely representable.
        value = amount.flatMap { !$0.isNaN && $0 >= 0 && $0 <= 1_000_000_000_000 ? $0 : nil }
    }
}

struct RecordedCostSummary: Equatable, Sendable {
    var usd: Decimal = 0
    var recordedOperations = 0

    mutating func add(_ cost: Decimal?) {
        if let cost {
            usd += cost
            recordedOperations += 1
        }
    }

    mutating func merge(_ other: Self) {
        usd += other.usd
        recordedOperations += other.recordedOperations
    }

    var display: String? { attributedDisplay.map { String($0.characters) } }

    var attributedDisplay: AttributedString? {
        guard recordedOperations > 0 else { return nil }
        // Keep currency metadata so the UI can style the unit separately from the amount.
        let subcent = usd > 0 && usd < Decimal(string: "0.01")!
        let amount = subcent ? Decimal(string: "0.01")! : usd
        let formatted = amount.formatted(.currency(code: "USD").attributed)
        return subcent ? AttributedString("< ") + formatted : formatted
    }
}
