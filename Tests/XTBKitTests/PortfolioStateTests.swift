import XCTest
@testable import XTBKit

final class PortfolioStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pln = XTBAccount(accountNo: "1", endpoint: "meta1", currency: "PLN", isArchived: false)
    private let eur = XTBAccount(accountNo: "2", endpoint: "meta1", currency: "EUR", isArchived: false)

    private func state(_ events: XTBEvent...) -> PortfolioState {
        var s = PortfolioState()
        events.forEach { s.apply($0) }
        return s
    }

    private func position(_ s: inout PortfolioState, id: Int, symbol: String, value: Double, profit: Double, account: String = "1") {
        s.apply(.trade(Trade(idPosition: id, symbolKey: symbol, isOpen: true, accountNo: account)))
        s.apply(.tradeProfit(TradeProfit(idPosition: id, profit: profit, marketValue: value)))
    }

    func testSnapshotNilUntilABalanceArrives() {
        var s = state(.loginResult([pln]))
        position(&s, id: 1, symbol: "AAPL.US", value: 100, profit: 10)
        XCTAssertNil(s.snapshot(account: "1", now: now))
        s.apply(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 10)))
        XCTAssertNotNil(s.snapshot(account: "1", now: now))
    }

    func testEachAccountGetsItsOwnSnapshot() throws {
        var s = state(.loginResult([pln, eur]),
                      .balance(TotalBalance(accountNo: "1", equity: 1000, profit: 100)),
                      .balance(TotalBalance(accountNo: "2", equity: 500, profit: -20)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 10, account: "1")
        position(&s, id: 2, symbol: "B", value: 50, profit: -5, account: "2")
        let all = s.snapshots(now: now)
        XCTAssertEqual(Set(all.keys), ["1", "2"])
        let first = try XCTUnwrap(all["1"]), second = try XCTUnwrap(all["2"])
        XCTAssertEqual(first.equity, 1000)
        XCTAssertEqual(first.currency, "PLN")
        XCTAssertEqual(first.positions.map(\.name), ["A"])
        XCTAssertEqual(second.profit, -20)
        XCTAssertEqual(second.currency, "EUR")
        XCTAssertEqual(second.positions.map(\.name), ["B"])
        XCTAssertEqual(first.updatedAt, now)
        XCTAssertTrue(first.connected)
        XCTAssertEqual(s.activeAccounts, ["1", "2"])
        XCTAssertEqual(s.accountsWithBalance, ["1", "2"])
    }

    func testCombinedConvertsCurrenciesAndMergesSameInstrument() throws {
        let plnPart = Snapshot(equity: 1000, profit: 100, profitPercent: 0, currency: "PLN",
                               positions: [PositionRow(name: "Apple", value: 400, profit: 40, profitPercent: 0)],
                               updatedAt: now, connected: true)
        let eurPart = Snapshot(equity: 100, profit: 10, profitPercent: 0, currency: "EUR",
                               positions: [PositionRow(name: "Apple", value: 50, profit: 5, profitPercent: 0),
                                           PositionRow(name: "SAP", value: 50, profit: 5, profitPercent: 0)],
                               updatedAt: now.addingTimeInterval(5), connected: false)
        let sum = try XCTUnwrap(Snapshot.combined([plnPart, eurPart], in: "PLN", rates: ["EUR": 4]))
        XCTAssertEqual(sum.equity, 1400)
        XCTAssertEqual(sum.profit, 140)
        XCTAssertEqual(sum.currency, "PLN")
        XCTAssertEqual(sum.positions, [PositionRow(name: "Apple", value: 600, profit: 60, profitPercent: 60.0 / 540 * 100),
                                       PositionRow(name: "SAP", value: 200, profit: 20, profitPercent: 20.0 / 180 * 100)])
        XCTAssertEqual(sum.updatedAt, now.addingTimeInterval(5))
        XCTAssertFalse(sum.connected)
        XCTAssertNil(Snapshot.combined([plnPart, eurPart], in: "PLN", rates: [:]))
        XCTAssertNil(Snapshot.combined([], in: "PLN", rates: [:]))
    }

    func testLaterBalanceOfSameAccountReplacesEarlier() throws {
        let s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 100)),
                      .balance(TotalBalance(accountNo: "1", equity: 1010, profit: 110)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).equity, 1010)
    }

    func testCurrencyIsEmptyWhenAccountUnknown() throws {
        let s = state(.balance(TotalBalance(accountNo: "9", equity: 1, profit: 0)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "9", now: now)).currency, "")
    }

    func testGroupsSameSymbolIntoOneRow() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)),
                      .instruments([Instrument(key: "AAPL.US", name: "Apple")]))
        position(&s, id: 1, symbol: "AAPL.US", value: 600, profit: 50)
        position(&s, id: 2, symbol: "AAPL.US", value: 500, profit: 50)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions,
                       [PositionRow(name: "Apple", value: 1100, profit: 100, profitPercent: 10)])
    }

    func testSortsByValueDescending() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        position(&s, id: 2, symbol: "B", value: 300, profit: 0)
        position(&s, id: 3, symbol: "C", value: 200, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.map(\.name), ["B", "C", "A"])
    }

    func testClosedPositionDisappears() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        position(&s, id: 2, symbol: "B", value: 300, profit: 0)
        s.apply(.trade(Trade(idPosition: 2, symbolKey: "B", isOpen: false, accountNo: "1")))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.map(\.name), ["A"])
        // A late profit update for the closed position must not bring it back.
        s.apply(.tradeProfit(TradeProfit(idPosition: 2, profit: 1, marketValue: 300)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.map(\.name), ["A"])
    }

    func testNewPositionAppears() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.count, 1)
        position(&s, id: 2, symbol: "B", value: 50, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.map(\.name), ["A", "B"])
    }

    func testProfitUpdateReplacesPrevious() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 10)
        s.apply(.tradeProfit(TradeProfit(idPosition: 1, profit: 20, marketValue: 110)))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions,
                       [PositionRow(name: "A", value: 110, profit: 20, profitPercent: 20 / 90 * 100)])
    }

    func testTradeWithoutProfitYetIsNotListed() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)))
        s.apply(.trade(Trade(idPosition: 1, symbolKey: "A", isOpen: true, accountNo: "1")))
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions, [])
    }

    func testNoPositionsGivesEmptyListAndZeroPercent() throws {
        let snap = try XCTUnwrap(state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0))).snapshot(account: "1", now: now))
        XCTAssertEqual(snap.positions, [])
        XCTAssertEqual(snap.profitPercent, 0)
    }

    func testMissingInstrumentFallsBackToSymbolKey() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 1000, profit: 0)),
                      .instruments([Instrument(key: "OTHER", name: "Other")]))
        position(&s, id: 1, symbol: "AMD.US", value: 100, profit: 0)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).positions.map(\.name), ["AMD.US"])
    }

    func testTotalPercentUsesCostOfAllPositions() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 5000, profit: 150)))
        position(&s, id: 1, symbol: "A", value: 1100, profit: 100)
        position(&s, id: 2, symbol: "B", value: 550, profit: 50)
        XCTAssertEqual(try XCTUnwrap(s.snapshot(account: "1", now: now)).profitPercent, 10, accuracy: 1e-9)
    }

    func testWorthlessPositionDoesNotDivideByZero() throws {
        var s = state(.balance(TotalBalance(accountNo: "1", equity: 0, profit: 100)))
        position(&s, id: 1, symbol: "A", value: 100, profit: 100)
        let snap = try XCTUnwrap(s.snapshot(account: "1", now: now))
        XCTAssertEqual(snap.positions.first?.profitPercent, 0)
        XCTAssertEqual(snap.profitPercent, 0)
    }
}
