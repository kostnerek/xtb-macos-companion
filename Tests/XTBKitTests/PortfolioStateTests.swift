import XCTest
@testable import XTBKit

final class PortfolioStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pln = XTBAccount(accountNo: "1", endpoint: "meta1", currency: "PLN", isArchived: false)
    private let second = XTBAccount(accountNo: "2", endpoint: "meta1", currency: "PLN", isArchived: false)

    private func state(_ events: XTBEvent...) -> PortfolioState {
        var s = PortfolioState()
        events.forEach { s.apply($0) }
        return s
    }

    private func position(_ s: inout PortfolioState, id: Int, symbol: String, value: Double, profit: Double) {
        s.apply(.trade(Trade(idPosition: id, symbolKey: symbol, isOpen: true)))
        s.apply(.tradeProfit(TradeProfit(idPosition: id, profit: profit, marketValue: value)))
    }

    func testSnapshotNilUntilABalanceArrives() {
        var s = state(.loginResult([pln]))
        position(&s, id: 1, symbol: "AAPL.US", value: 100, profit: 10)
        XCTAssertNil(s.snapshot(now: now))
        s.apply(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 10)))
        XCTAssertNotNil(s.snapshot(now: now))
    }

    func testSumsBalancesAcrossAccounts() throws {
        let s = state(.loginResult([pln, second]),
                      .balance(TotalBalance(accountNo: "1", equity: 1000, profit: 100)),
                      .balance(TotalBalance(accountNo: "2", equity: 500, profit: -20)))
        let snap = try XCTUnwrap(s.snapshot(now: now))
        XCTAssertEqual(snap.equity, 1500)
        XCTAssertEqual(snap.profit, 80)
        XCTAssertEqual(snap.currency, "PLN")
        XCTAssertEqual(snap.updatedAt, now)
        XCTAssertTrue(snap.connected)
    }

    func testLaterBalanceOfSameAccountReplacesEarlier() throws {
        let s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 100)),
                      .balance(TotalBalance(accountNo: "1", equity: 1010, profit: 110)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).equity, 1010)
    }

    func testCurrencyIsEmptyWhenAccountUnknown() throws {
        let s = state(.balance(TotalBalance(accountNo: "9", equity: 1, profit: 0)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).currency, "")
    }

    func testGroupsSameSymbolIntoOneRow() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)),
                      .instruments([Instrument(key: "AAPL.US", name: "Apple")]))
        position(&s, id: 1, symbol: "AAPL.US", value: 600, profit: 50)
        position(&s, id: 2, symbol: "AAPL.US", value: 500, profit: 50)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions,
                       [PositionRow(name: "Apple", value: 1100, profit: 100, profitPercent: 10)])
    }

    func testSortsByValueDescending() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        position(&s, id: 2, symbol: "B", value: 300, profit: 0)
        position(&s, id: 3, symbol: "C", value: 200, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.map(\.name), ["B", "C", "A"])
    }

    func testClosedPositionDisappears() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        position(&s, id: 2, symbol: "B", value: 300, profit: 0)
        s.apply(.trade(Trade(idPosition: 2, symbolKey: "B", isOpen: false)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.map(\.name), ["A"])
        // A late profit update for the closed position must not bring it back.
        s.apply(.tradeProfit(TradeProfit(idPosition: 2, profit: 1, marketValue: 300)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.map(\.name), ["A"])
    }

    func testNewPositionAppears() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.count, 1)
        position(&s, id: 2, symbol: "B", value: 50, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.map(\.name), ["A", "B"])
    }

    func testProfitUpdateReplacesPrevious() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 10)
        s.apply(.tradeProfit(TradeProfit(idPosition: 1, profit: 20, marketValue: 110)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions,
                       [PositionRow(name: "A", value: 110, profit: 20, profitPercent: 20 / 90 * 100)])
    }

    func testTradeWithoutProfitYetIsNotListed() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        s.apply(.trade(Trade(idPosition: 1, symbolKey: "A", isOpen: true)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions, [])
    }

    func testNoPositionsGivesEmptyListAndZeroPercent() throws {
        let snap = try XCTUnwrap(state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0))).snapshot(now: now))
        XCTAssertEqual(snap.positions, [])
        XCTAssertEqual(snap.profitPercent, 0)
    }

    func testMissingInstrumentFallsBackToSymbolKey() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)),
                      .instruments([Instrument(key: "OTHER", name: "Other")]))
        position(&s, id: 1, symbol: "AMD.US", value: 100, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).positions.map(\.name), ["AMD.US"])
    }

    func testTotalPercentUsesCostOfAllPositions() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 5000, profit: 150)))
        position(&s, id: 1, symbol: "A", value: 1100, profit: 100)
        position(&s, id: 2, symbol: "B", value: 550, profit: 50)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(now: now)).profitPercent, 10, accuracy: 1e-9)
    }

    func testWorthlessPositionDoesNotDivideByZero() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 0, profit: 100)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 100)
        let snap = try XCTUnwrap(s.snapshot(now: now))
        XCTAssertEqual(snap.positions.first?.profitPercent, 0)
        XCTAssertEqual(snap.profitPercent, 0)
    }
}
