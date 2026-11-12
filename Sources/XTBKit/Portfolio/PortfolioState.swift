import Foundation

/// Folds the event stream into what the app shows: one snapshot per account, each with one row
/// per instrument.
public struct PortfolioState: Sendable {
    private var accounts: [String: XTBAccount] = [:]
    private var balances: [String: TotalBalance] = [:]
    private var openTrades: [Int: Trade] = [:]
    private var profits: [Int: TradeProfit] = [:]
    private var instrumentNames: [String: String] = [:]

    public init() {}

    public mutating func apply(_ event: XTBEvent) {
        switch event {
        case .loginResult(let list):
            for account in list { accounts[account.accountNo] = account }
        case .balance(let balance):
            balances[balance.accountNo] = balance
        case .trade(let trade):
            if trade.isOpen {
                openTrades[trade.idPosition] = trade
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

    /// Accounts the login announced and that are still in use, in account-number order.
    public var activeAccounts: [String] {
        accounts.values.filter { !$0.isArchived }.map(\.accountNo).sorted()
    }

    /// Accounts a balance has arrived for.
    public var accountsWithBalance: Set<String> { Set(balances.keys) }

    /// For the log: which accounts the page announced and which sent a balance (last 3 digits only).
    public var diagnostics: String {
        let announced = accounts.values.map { "…\($0.accountNo.suffix(3)) \($0.currency)\($0.isArchived ? " archived" : "")" }
        let balanced = balances.keys.sorted().map { "…\($0.suffix(3))" }
        return "accounts \(announced), balances from \(balanced), open trades \(openTrades.count)"
    }

    /// One snapshot for every account a balance has arrived for, keyed by account number.
    public func snapshots(now: Date) -> [String: Snapshot] {
        Dictionary(uniqueKeysWithValues: balances.keys.compactMap { no in snapshot(account: no, now: now).map { (no, $0) } })
    }

    /// Nil until that account's balance has arrived.
    public func snapshot(account accountNo: String, now: Date) -> Snapshot? {
        guard let balance = balances[accountNo] else { return nil }
        var bySymbol: [String: (value: Double, profit: Double)] = [:]
        for (id, trade) in openTrades where trade.accountNo == accountNo {
            guard let p = profits[id] else { continue }
            let sum = bySymbol[trade.symbolKey] ?? (0, 0)
            bySymbol[trade.symbolKey] = (sum.value + p.marketValue, sum.profit + p.profit)
        }
        let rows = bySymbol.map { symbol, sum in
            PositionRow(name: instrumentNames[symbol] ?? symbol, value: sum.value, profit: sum.profit,
                        profitPercent: profitPercent(profit: sum.profit, value: sum.value))
        }
        return Snapshot(equity: balance.equity, profit: balance.profit, currency: accounts[accountNo]?.currency ?? "",
                        positions: rows, updatedAt: now)
    }
}

/// Profit relative to what the positions cost: value minus profit.
func profitPercent(profit: Double, value: Double) -> Double {
    let cost = value - profit
    return cost > 0 ? profit / cost * 100 : 0
}
