import XCTest
@testable import XTBKit

final class SampleStoreTests: XCTestCase {
    private var dir: URL!
    private var store: SampleStore!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("xtb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SampleStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(hoursAgo: Double, profit: Double = 1) -> Sample {
        Sample(t: now.addingTimeInterval(-hoursAgo * 3600), equity: 1000 + profit, profit: profit)
    }

    func testAppendThenReadAll() throws {
        let a = sample(hoursAgo: 2, profit: 10), b = sample(hoursAgo: 1, profit: 20)
        try store.append(a)
        try store.append(b)
        XCTAssertEqual(store.samples(in: .all, now: now), [a, b])
    }

    func testRangeDayReturnsOnlyLast24h() throws {
        let old = sample(hoursAgo: 25), recent = sample(hoursAgo: 23)
        try store.append(old)
        try store.append(recent)
        XCTAssertEqual(store.samples(in: .day, now: now), [recent])
    }

    func testRangeWeekAndMonthBoundaries() throws {
        let d8 = sample(hoursAgo: 8 * 24), d6 = sample(hoursAgo: 6 * 24), d31 = sample(hoursAgo: 31 * 24), d29 = sample(hoursAgo: 29 * 24)
        for s in [d31, d29, d8, d6] { try store.append(s) }
        XCTAssertEqual(store.samples(in: .week, now: now), [d6])
        XCTAssertEqual(store.samples(in: .month, now: now), [d29, d8, d6])
        XCTAssertEqual(store.samples(in: .all, now: now).count, 4)
    }

    func testTruncatedLastLineIsSkipped() throws {
        let a = sample(hoursAgo: 2), b = sample(hoursAgo: 1)
        try store.append(a)
        try store.append(b)
        let file = dir.appendingPathComponent("samples.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"t\":17".utf8))
        try handle.close()
        XCTAssertEqual(store.samples(in: .all, now: now), [a, b])
    }

    func testAppendAfterTruncatedLineStillReadable() throws {
        let a = sample(hoursAgo: 2), b = sample(hoursAgo: 1)
        try store.append(a)
        let file = dir.appendingPathComponent("samples.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"t\":17".utf8))
        try handle.close()
        try store.append(b)
        XCTAssertEqual(store.samples(in: .all, now: now), [a, b])
    }

    func testMissingFileGivesEmpty() {
        XCTAssertEqual(store.samples(in: .all, now: now), [])
    }

    func testSnapshotRoundTrip() throws {
        let snapshot = Snapshot(equity: 42310.5, profit: 3314.25, profitPercent: 8.5, currency: "PLN",
                                positions: [PositionRow(name: "Apple", value: 8960, profit: 1120, profitPercent: 14.3)],
                                updatedAt: now, connected: true)
        try store.writeSnapshot(snapshot)
        XCTAssertEqual(store.readSnapshot(), snapshot)
    }

    func testReadSnapshotNilWhenMissingOrCorrupt() throws {
        XCTAssertNil(store.readSnapshot())
        try Data("{\"equity\":".utf8).write(to: dir.appendingPathComponent("snapshot.json"))
        XCTAssertNil(store.readSnapshot())
    }
}
