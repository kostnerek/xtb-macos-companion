import Foundation

/// Today's change in total profit: current profit minus the last sample taken before today's
/// local midnight, however old that sample is. Nil when there is no earlier sample.
public func dailyChange(currentProfit: Double, samples: [Sample], now: Date, calendar: Calendar) -> Double? {
    let midnight = calendar.startOfDay(for: now)
    guard let baseline = samples.last(where: { $0.t < midnight }) else { return nil }
    return currentProfit - baseline.profit
}

/// The next full quarter of an hour strictly after `date`.
public func nextSampleDate(after date: Date) -> Date {
    let quarter: TimeInterval = 15 * 60
    return Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / quarter) + 1) * quarter)
}

/// Splits history where samples are further apart than `maxGap`, so a chart shows a break
/// instead of a straight line across the time the app was not running.
public func segments(_ samples: [Sample], maxGap: TimeInterval) -> [[Sample]] {
    var result: [[Sample]] = []
    for sample in samples {
        if let last = result.last?.last, sample.t.timeIntervalSince(last.t) <= maxGap {
            result[result.count - 1].append(sample)
        } else {
            result.append([sample])
        }
    }
    return result
}
