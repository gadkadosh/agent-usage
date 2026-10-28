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
    var missingOperations = 0

    mutating func add(_ cost: Decimal?) {
        if let cost {
            usd += cost
            recordedOperations += 1
        } else {
            missingOperations += 1
        }
    }

    var display: String {
        if recordedOperations == 0 && missingOperations > 0 { return "Unavailable" }
        // Preserve sub-cent usage instead of rounding a nonzero amount to $0.00.
        let amount =
            usd > 0 && usd < Decimal(string: "0.01")!
            ? "< $0.01" : usd.formatted(.currency(code: "USD"))
        return missingOperations > 0 ? "\(amount) (partial)" : amount
    }
}
