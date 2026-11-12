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

/// Everything the menu bar and the widget show, summed over all accounts.
public struct Snapshot: Codable, Equatable, Sendable {
    public let equity: Double
    public let profit: Double
    public let profitPercent: Double
    public let currency: String
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
}
