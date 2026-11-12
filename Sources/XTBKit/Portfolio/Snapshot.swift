import Foundation

/// One line of the positions list: all open trades on one instrument, across all accounts.
public struct PositionRow: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double
    public let profit: Double
    public let profitPercent: Double

    public init(name: String, value: Double, profit: Double, profitPercent: Double) {
        self.name = name
        self.value = value
        self.profit = profit
        self.profitPercent = profitPercent
    }
}

/// Everything the menu bar and the widget show for one account, or for all accounts summed.
public struct Snapshot: Codable, Equatable, Sendable {
    public let equity: Double
    public let profit: Double
    public let profitPercent: Double
    public let currency: String
    /// Largest value first.
    public let positions: [PositionRow]
    public let updatedAt: Date
    /// False once the live connection is gone, so readers can show the data as stale.
    public var connected: Bool

    public init(equity: Double, profit: Double, profitPercent: Double, currency: String,
                positions: [PositionRow], updatedAt: Date, connected: Bool) {
        self.equity = equity
        self.profit = profit
        self.profitPercent = profitPercent
        self.currency = currency
        self.positions = positions
        self.updatedAt = updatedAt
        self.connected = connected
    }

    /// A live snapshot whose total percent is worked out from the positions' cost.
    init(equity: Double, profit: Double, currency: String, positions: [PositionRow], updatedAt: Date) {
        self.init(equity: equity, profit: profit,
                  profitPercent: XTBKit.profitPercent(profit: positions.reduce(0) { $0 + $1.profit },
                                                      value: positions.reduce(0) { $0 + $1.value }),
                  currency: currency, positions: positions.sorted { ($0.value, $1.name) > ($1.value, $0.name) },
                  updatedAt: updatedAt, connected: true)
    }

    /// All accounts summed in `currency`. `rates` gives the price of one unit of each account's
    /// currency in `currency`. Rows of the same instrument held on several accounts are merged.
    /// Nil when there is nothing to sum or a rate is missing.
    public static func combined(_ parts: [Snapshot], in currency: String, rates: [String: Double]) -> Snapshot? {
        guard let latest = parts.map(\.updatedAt).max() else { return nil }
        var equity = 0.0, profit = 0.0
        var rows: [String: (value: Double, profit: Double)] = [:]
        for part in parts {
            guard let rate = part.currency == currency ? 1 : rates[part.currency] else { return nil }
            equity += part.equity * rate
            profit += part.profit * rate
            for row in part.positions {
                let sum = rows[row.name] ?? (0, 0)
                rows[row.name] = (sum.value + row.value * rate, sum.profit + row.profit * rate)
            }
        }
        let positions = rows.map { name, sum in
            PositionRow(name: name, value: sum.value, profit: sum.profit,
                        profitPercent: XTBKit.profitPercent(profit: sum.profit, value: sum.value))
        }
        var result = Snapshot(equity: equity, profit: profit, currency: currency, positions: positions, updatedAt: latest)
        result.connected = parts.allSatisfy(\.connected)
        return result
    }
}
