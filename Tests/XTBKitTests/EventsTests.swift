import XCTest
@testable import XTBKit

func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

final class EventsTests: XCTestCase {
    func testLoginResultListsAccounts() {
        XCTAssertEqual(decodeEvents(fixture("login_result")), [.loginResult([
            XTBAccount(accountNo: "10000001", endpoint: "meta1", currency: "PLN", isArchived: false),
            XTBAccount(accountNo: "10000002", endpoint: "meta1", currency: "EUR", isArchived: false),
        ])])
        XCTAssertEqual(XTBAccount(accountNo: "10000001", endpoint: "meta1", currency: "PLN", isArchived: false).accountId, "meta1_10000001")
    }

    func testBalanceEvent() {
        XCTAssertEqual(decodeEvents(fixture("total_balance")),
                       [.balance(TotalBalance(accountNo: "10000001", equity: 29357.53, profit: 3343.61))])
    }

    func testBalanceInSubscriptionResponse() {
        XCTAssertEqual(decodeEvents(fixture("total_balance_response")),
                       [.balance(TotalBalance(accountNo: "10000001", equity: 29357.03, profit: 3343.11))])
    }

    func testEmptySubscriptionResponseGivesNothing() {
        XCTAssertEqual(decodeEvents(fixture("empty_response")), [])
    }

    func testTradeProfitEvent() {
        XCTAssertEqual(decodeEvents(fixture("trade_profit")),
                       [.tradeProfit(TradeProfit(idPosition: -1494572831, profit: 26, marketValue: 497))])
    }

    func testTradeProfitResponseGivesOneEventPerPosition() {
        XCTAssertEqual(decodeEvents(fixture("trade_profit_response")), [
            .tradeProfit(TradeProfit(idPosition: -1637135387, profit: 6.7, marketValue: 106.95)),
            .tradeProfit(TradeProfit(idPosition: -2088540011, profit: -2.06, marketValue: 1159.88)),
        ])
    }

    func testTradeRecordResponse() {
        XCTAssertEqual(decodeEvents(fixture("trade_record")), [
            .trade(Trade(idPosition: -1929030355, symbolKey: "AC.FR", isOpen: true)),
            .trade(Trade(idPosition: -1456307190, symbolKey: "AMZN.US", isOpen: true)),
        ])
    }

    func testTradeEvent() {
        XCTAssertEqual(decodeEvents(fixture("trade_event")),
                       [.trade(Trade(idPosition: -1556578014, symbolKey: "AMD.US", isOpen: true))])
    }

    func testDeletedTradeRowIsNotOpen() throws {
        let text = String(decoding: fixture("trade_event"), as: UTF8.self)
            .replacingOccurrences(of: "\"row\":{\"state\":1", with: "\"row\":{\"state\":2")
        XCTAssertEqual(decodeEvents(Data(text.utf8)),
                       [.trade(Trade(idPosition: -1556578014, symbolKey: "AMD.US", isOpen: false))])
    }

    func testInstrumentsAreGroupedIntoOneEvent() {
        XCTAssertEqual(decodeEvents(fixture("symbols")), [.instruments([
            Instrument(key: "WLY.US", name: "John Wiley & Sons"),
            Instrument(key: "GOOGL.US", name: "Alphabet"),
            Instrument(key: "VOD.US", name: "Vodafone"),
        ])])
    }

    func testUnknownElementIsSkipped() {
        XCTAssertEqual(decodeEvents(fixture("unknown_event")), [])
    }

    func testGarbageIsSkipped() {
        XCTAssertEqual(decodeEvents(Data("not json".utf8)), [])
        XCTAssertEqual(decodeEvents(Data("[1794478338347]".utf8)), [])
        XCTAssertEqual(decodeEvents(Data("{\"events\":\"oops\"}".utf8)), [])
        XCTAssertEqual(decodeEvents(Data()), [])
    }

    func testKnownShapeWithMissingFieldIsSkipped() {
        let text = String(decoding: fixture("total_balance"), as: UTF8.self)
            .replacingOccurrences(of: "\"totalEquity\":29357.53,", with: "")
        XCTAssertEqual(decodeEvents(Data(text.utf8)), [])
    }

    func testMixedBatchKeepsValidEvents() {
        let balance = String(decoding: fixture("total_balance"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
        let unknown = String(decoding: fixture("unknown_event"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
        let batch = "[\(unknown),\(balance)]"
        XCTAssertEqual(decodeEvents(Data(batch.utf8)),
                       [.balance(TotalBalance(accountNo: "10000001", equity: 29357.53, profit: 3343.61))])
    }

    func testNonZeroStatusOnRequestBecomesRequestFailed() {
        let text = "[{\"reqId\":\"loginWithServiceTicket_1_1\",\"status\":5,\"completed\":true}]"
        XCTAssertEqual(decodeEvents(Data(text.utf8)), [.requestFailed(reqId: "loginWithServiceTicket_1_1", status: 5)])
    }
}
