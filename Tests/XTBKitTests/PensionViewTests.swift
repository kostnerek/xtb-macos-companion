import XCTest
@testable import XTBKit

/// Amounts here are made up; the text shapes follow xStation's IKE and IKZE views.
final class PensionViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let row = ["Delta", "Akcje", "DEL.PL", "3", "@ 50.00", "300.00 PLN", "-20.00 PLN", "-6.25 %", "Buy", "Sell"]

    func testProfitSummaryAndRows() throws {
        let text = "x IKZE Zarządzaj Inwestuj 12 345.67 PLN Zysk: +1 000.50 (8.82%) Wartość"
        let rows = [["Alfa", "Akcje", "ALF.PL", "10", "@ 1.00", "100.00 PLN", "10.00 PLN", "11.11 %", "Buy", "Sell"],
                    ["Beta", "ETF", "BET.PL", "5", "@ 2.00", "2 000.00 PLN", "-50.00 PLN", "-2.44 %"]]
        let snapshot = try XCTUnwrap(pensionSnapshot(label: "IKZE", text: text, rows: rows, now: now))
        XCTAssertEqual(snapshot.equity, 12345.67, accuracy: 0.001)
        XCTAssertEqual(snapshot.profit, 1000.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.profitPercent, 8.82, accuracy: 0.001)
        XCTAssertEqual(snapshot.currency, "PLN")
        XCTAssertTrue(snapshot.connected)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.positions, [
            PositionRow(name: "Beta", value: 2000, profit: -50, profitPercent: -2.44),
            PositionRow(name: "Alfa", value: 100, profit: 10, profitPercent: 11.11),
        ])
    }

    /// An account at a loss says "Strata:" where one in profit says "Zysk:".
    func testLossUsesStrataLabel() throws {
        let text = "IKE Zarządzaj Inwestuj 26 000.00 PLN Strata: -2 500.00 (-8.77%) Wartość rynkowa"
        let snapshot = try XCTUnwrap(pensionSnapshot(label: "IKE", text: text, rows: [row], now: now))
        XCTAssertEqual(snapshot.equity, 26000, accuracy: 0.001)
        XCTAssertEqual(snapshot.profit, -2500, accuracy: 0.001)
        XCTAssertEqual(snapshot.profitPercent, -8.77, accuracy: 0.001)
    }

    func testUnicodeMinus() throws {
        let text = "IKE Zarządzaj Inwestuj 26 000.00 PLN Strata: \u{2212}2 500.00 (\u{2212}8.77%)"
        let snapshot = try XCTUnwrap(pensionSnapshot(label: "IKE", text: text, rows: [row], now: now))
        XCTAssertEqual(snapshot.profit, -2500, accuracy: 0.001)
        XCTAssertEqual(snapshot.profitPercent, -8.77, accuracy: 0.001)
    }

    func testLabelMustMatchExactly() {
        let ikze = "IKZE Zarządzaj Inwestuj 1 000.00 PLN Zysk: 10.00 (1.01%)"
        let ike = "IKE Zarządzaj Inwestuj 1 000.00 PLN Zysk: 10.00 (1.01%)"
        XCTAssertNil(pensionSnapshot(label: "IKE", text: ikze, rows: [row], now: now))
        XCTAssertNil(pensionSnapshot(label: "IKZE", text: ike, rows: [row], now: now))
    }

    /// The view shows its summary before its table; an empty table means it is still loading.
    func testNilWithoutRows() {
        let text = "IKE Zarządzaj Inwestuj 1 000.00 PLN Zysk: 10.00 (1.01%)"
        XCTAssertNil(pensionSnapshot(label: "IKE", text: text, rows: [], now: now))
    }

    func testRowWithoutAmountsIsSkipped() throws {
        let text = "IKE Zarządzaj Inwestuj 1 000.00 PLN Zysk: 10.00 (1.01%)"
        let snapshot = try XCTUnwrap(pensionSnapshot(label: "IKE", text: text, rows: [["Gamma", "Akcje"], row], now: now))
        XCTAssertEqual(snapshot.positions, [PositionRow(name: "Delta", value: 300, profit: -20, profitPercent: -6.25)])
    }
}
