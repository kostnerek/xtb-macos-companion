import Foundation

/// One point of history, taken every 15 minutes while connected.
public struct Sample: Codable, Equatable, Sendable {
    public let t: Date
    public let equity: Double
    public let profit: Double

    public init(t: Date, equity: Double, profit: Double) {
        self.t = t
        self.equity = equity
        self.profit = profit
    }
}

public enum ChartRange: String, CaseIterable, Codable, Sendable {
    case day, week, month, all

    var interval: TimeInterval? {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        case .all: nil
        }
    }
}

/// History and the latest snapshot, kept as two files in one directory
/// (the App Group container, so the widget can read what the app writes).
public struct SampleStore: Sendable {
    private let samplesURL: URL
    private let snapshotURL: URL

    public init(directory: URL) {
        samplesURL = directory.appendingPathComponent("samples.jsonl")
        snapshotURL = directory.appendingPathComponent("snapshot.json")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public func append(_ sample: Sample) throws {
        var line = try Self.encoder.encode(sample)
        line.append(0x0A)
        guard let handle = try? FileHandle(forUpdating: samplesURL) else {
            try line.write(to: samplesURL, options: .atomic)
            return
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A crash mid-write can leave a partial last line; start ours on a fresh line.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Samples in file order. Lines that do not decode are skipped.
    public func samples(in range: ChartRange, now: Date) -> [Sample] {
        guard let data = try? Data(contentsOf: samplesURL) else { return [] }
        let cutoff = range.interval.map { now.addingTimeInterval(-$0) }
        return data.split(separator: 0x0A).compactMap { line in
            guard let sample = try? Self.decoder.decode(Sample.self, from: Data(line)) else { return nil }
            if let cutoff, sample.t < cutoff { return nil }
            return sample
        }
    }

    public func writeSnapshot(_ snapshot: Snapshot) throws {
        try Self.encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    public func readSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? Self.decoder.decode(Snapshot.self, from: data)
    }
}
