import XCTest
@testable import XTBKit

final class DailyChangeTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private func sample(_ t: Date, _ profit: Double) -> Sample { Sample(t: t, equity: 0, profit: profit) }

    func testUsesLastSampleBeforeTodayMidnight() {
        let samples = [sample(date(2026, 11, 11, 15, 0), 80), sample(date(2026, 11, 11, 21, 45), 100), sample(date(2026, 11, 12, 9, 0), 130)]
        XCTAssertEqual(dailyChange(currentProfit: 150, samples: samples, now: date(2026, 11, 12, 11, 0), calendar: calendar), 50)
    }

    func testMondayUsesFridaySample() {
        let samples = [sample(date(2026, 11, 13, 21, 45), 200), sample(date(2026, 11, 16, 9, 0), 260)]
        XCTAssertEqual(dailyChange(currentProfit: 250, samples: samples, now: date(2026, 11, 16, 10, 0), calendar: calendar), 50)
    }

    func testNilWhenNoEarlierSample() {
        let samples = [sample(date(2026, 11, 12, 0, 0), 100), sample(date(2026, 11, 12, 9, 0), 130)]
        XCTAssertNil(dailyChange(currentProfit: 150, samples: samples, now: date(2026, 11, 12, 11, 0), calendar: calendar))
        XCTAssertNil(dailyChange(currentProfit: 150, samples: [], now: date(2026, 11, 12, 11, 0), calendar: calendar))
    }

    /// 2026-10-25 has 25 hours in Warsaw; "today" must start at local midnight, not 12 hours before noon.
    func testAcrossDSTChange() {
        let samples = [sample(date(2026, 10, 24, 23, 50), 10), sample(date(2026, 10, 25, 0, 10), 20)]
        XCTAssertEqual(dailyChange(currentProfit: 35, samples: samples, now: date(2026, 10, 25, 12, 0), calendar: calendar), 25)
    }

    func testNextSampleDateRoundsUpToQuarter() {
        XCTAssertEqual(nextSampleDate(after: date(2026, 11, 12, 10, 7, 30)), date(2026, 11, 12, 10, 15))
        XCTAssertEqual(nextSampleDate(after: date(2026, 11, 12, 10, 15)), date(2026, 11, 12, 10, 30))
        XCTAssertEqual(nextSampleDate(after: date(2026, 11, 12, 23, 59, 59)), date(2026, 11, 13, 0, 0))
    }

    func testSegmentsSplitOnGap() {
        let t0 = date(2026, 11, 12, 9, 0)
        let a = sample(t0, 1), b = sample(t0.addingTimeInterval(900), 2), c = sample(t0.addingTimeInterval(900 + 3 * 3600), 3), d = sample(t0.addingTimeInterval(1800 + 3 * 3600), 4)
        XCTAssertEqual(segments([a, b, c, d], maxGap: 45 * 60), [[a, b], [c, d]])
        XCTAssertEqual(segments([a, b], maxGap: 45 * 60), [[a, b]])
        XCTAssertEqual(segments([], maxGap: 45 * 60), [])
    }
}
