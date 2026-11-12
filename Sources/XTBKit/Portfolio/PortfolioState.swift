import Foundation

/// Folds the event stream into what the app shows: totals summed over accounts and one row
/// per instrument.
public struct PortfolioState: Sendable {
    private var accounts: [String: XTBAccount] = [:]
    private var balances: [String: TotalBalance] = [:]
    private var balanceOrder: [String] = []
    private var openTrades: [Int: String] = [:]
    private var profits: [Int: TradeProfit] = [:]
    private var instrumentNames: [String: String] = [:]

    public init() {}

    public mutating func apply(_ event: XTBEvent) {
        switch event {
        case .loginResult(let list):
            for account in list { accounts[account.accountNo] = account }
        case .balance(let balance):
            if balances[balance.accountNo] == nil { balanceOrder.append(balance.accountNo) }
            balances[balance.accountNo] = balance
        case .trade(let trade):
            if trade.isOpen {
                openTrades[trade.idPosition] = trade.symbolKey
            } else {
                openTrades[trade.idPosition] = nil
                profits[trade.idPosition] = nil
            }
        case .tradeProfit(let profit):
            profits[profit.idPosition] = profit
        case .instruments(let list):
            for instrument in list { instrumentNames[instrument.key] = instrument.name }
        case .requestFailed:
            break
        }
    }

    /// Nil until at least one account balance has arrived.
    public func snapshot(now: Date) -> Snapshot? {
        guard !balances.isEmpty else { return nil }

        var bySymbol: [String: (value: Double, profit: Double)] = [:]
        for (id, symbol) in openTrades {
            guard let p = profits[id] else { continue }
            let sum = bySymbol[symbol] ?? (0, 0)
            bySymbol[symbol] = (sum.value + p.marketValue, sum.profit + p.profit)
        }
        let rows = bySymbol
            .map { symbol, sum in
                PositionRow(name: instrumentNames[symbol] ?? symbol, value: sum.value, profit: sum.profit,
                            profitPercent: Self.percent(profit: sum.profit, value: sum.value))
            }
            .sorted { ($0.value, $1.name) > ($1.value, $0.name) }

        let currency = balanceOrder.lazy.compactMap { accounts[$0]?.currency }.first ?? ""
        return Snapshot(
            equity: balances.values.reduce(0) { $0 + $1.equity },
            profit: balances.values.reduce(0) { $0 + $1.profit },
            profitPercent: Self.percent(profit: rows.reduce(0) { $0 + $1.profit }, value: rows.reduce(0) { $0 + $1.value }),
            currency: currency,
            positions: rows,
            updatedAt: now,
            connected: true
        )
    }

    /// Profit relative to what the positions cost: value minus profit.
    private static func percent(profit: Double, value: Double) -> Double {
        let cost = value - profit
        return cost > 0 ? profit / cost * 100 : 0
    }
}
