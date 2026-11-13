import Foundation

/// Pension accounts xStation shows in their own views, in the order they are read.
/// The raw value is the key their snapshots and history are saved under.
public enum PensionAccount: String, CaseIterable, Sendable {
    case ikze, ike

    /// The account's name in xStation's side bar and at the top of its view.
    public var label: String { rawValue.uppercased() }
}

/// Reads a pension account (IKE, IKZE) from the text of its xStation view. These accounts do not
/// come through the page's socket, so their numbers are taken from what the view shows.
///
/// - Parameters:
///   - label: the account's name in xStation's side bar, e.g. "IKZE".
///   - text: all text of the view, whitespace collapsed to single spaces. Its summary reads
///     "<label> Zarządzaj Inwestuj <value> PLN Zysk: <profit> (<percent>%)", with "Strata:"
///     in place of "Zysk:" while the account is at a loss.
///   - rows: the lines of each visible position row: name first, then value and profit as
///     "<amount> PLN", and the profit percent as "<percent> %".
/// - Returns: nil until both the summary and at least one row are on screen.
public func pensionSnapshot(label: String, text: String, rows: [[String]], now: Date) -> Snapshot? {
    let text = text.replacingOccurrences(of: "\u{2212}", with: "-")
    let amount = "[-+]?[\\d .,]+?"
    let pattern = "(?:^| )\(NSRegularExpression.escapedPattern(for: label)) Zarządzaj Inwestuj (\(amount)) ?PLN (?:Zysk|Strata): ?(\(amount)) ?\\( ?([-+]?[\\d.,]+) ?%\\)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    let group = { (i: Int) in Range(match.range(at: i), in: text).flatMap { amountValue(String(text[$0])) } }
    guard let value = group(1), let profit = group(2), let percent = group(3) else { return nil }

    let positions = rows.compactMap(positionRow).sorted { $0.value > $1.value }
    guard !positions.isEmpty else { return nil }
    return Snapshot(equity: value, profit: profit, profitPercent: percent, currency: "PLN",
                    positions: positions, updatedAt: now, connected: true)
}

/// A row without both amounts or its percent (one still loading) is left out.
private func positionRow(_ lines: [String]) -> PositionRow? {
    let lines = lines.map { $0.replacingOccurrences(of: "\u{2212}", with: "-") }
    let amounts = lines.filter { $0.hasSuffix(" PLN") }.compactMap { amountValue(String($0.dropLast(4))) }
    guard let name = lines.first, amounts.count >= 2,
          let percent = lines.first(where: { $0.hasSuffix("%") }).flatMap({ amountValue(String($0.dropLast())) })
    else { return nil }
    return PositionRow(name: name, value: amounts[0], profit: amounts[1], profitPercent: percent)
}

/// "-1 234.56", "+1 000,50", "7.25" → number; spaces (also non-breaking) are thousands separators.
private func amountValue(_ text: String) -> Double? {
    let cleaned = text.filter { !$0.isWhitespace }.replacingOccurrences(of: ",", with: ".")
    return Double(cleaned.hasPrefix("+") ? String(cleaned.dropFirst()) : cleaned)
}

/// Whether the view offers to open the account ("Otwórz konto IKZE") instead of showing it,
/// which is what someone without that account sees after clicking it in the side bar.
public func pensionAccountMissing(label: String, text: String) -> Bool {
    let pattern = "Otwórz konto \(NSRegularExpression.escapedPattern(for: label))(?: |$)"
    return text.range(of: pattern, options: .regularExpression) != nil
}
