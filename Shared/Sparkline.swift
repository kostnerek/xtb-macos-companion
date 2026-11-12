import SwiftUI

/// A line chart without axes. Each segment is drawn separately, so gaps in history stay gaps.
struct Sparkline: Shape {
    let segments: [[Double]]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let all = segments.flatMap { $0 }
        guard let low = all.min(), let high = all.max() else { return path }
        let count = all.count
        let span = high - low
        func point(_ index: Int, _ value: Double) -> CGPoint {
            let x = count > 1 ? rect.minX + rect.width * CGFloat(index) / CGFloat(count - 1) : rect.midX
            let y = span > 0 ? rect.maxY - rect.height * CGFloat((value - low) / span) : rect.midY
            return CGPoint(x: x, y: y)
        }
        if count == 1 {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
        var index = 0
        for segment in segments {
            for (offset, value) in segment.enumerated() {
                let p = point(index, value)
                if offset == 0 { path.move(to: p) } else { path.addLine(to: p) }
                index += 1
            }
        }
        return path
    }
}

enum Money {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.groupingSeparator = "\u{00A0}"
        f.usesGroupingSeparator = true
        return f
    }()

    private static func unit(_ currency: String) -> String { currency == "PLN" ? "zł" : currency }

    static func plain(_ amount: Double, _ currency: String) -> String {
        "\(formatter.string(from: NSNumber(value: amount)) ?? "0")\u{00A0}\(unit(currency))"
    }

    static func signed(_ amount: Double, _ currency: String) -> String {
        (amount < 0 ? "−" : "+") + plain(abs(amount), currency)
    }

    static func percent(_ value: Double) -> String {
        (value < 0 ? "−" : "+") + String(format: "%.1f", abs(value)).replacingOccurrences(of: ".", with: ",") + "%"
    }
}
