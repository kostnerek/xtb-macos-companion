import Foundation

public struct XTBAccount: Equatable, Sendable {
    public let accountNo: String
    public let endpoint: String
    public let currency: String
    public let isArchived: Bool

    public init(accountNo: String, endpoint: String, currency: String, isArchived: Bool) {
        self.accountNo = accountNo
        self.endpoint = endpoint
        self.currency = currency
        self.isArchived = isArchived
    }

    /// The id the server expects in `accountId` of account-scoped requests.
    public var accountId: String { "\(endpoint)_\(accountNo)" }
}

public struct TotalBalance: Equatable, Sendable {
    public let accountNo: String
    public let equity: Double
    public let profit: Double

    public init(accountNo: String, equity: Double, profit: Double) {
        self.accountNo = accountNo
        self.equity = equity
        self.profit = profit
    }
}

public struct TradeProfit: Equatable, Sendable {
    public let idPosition: Int
    public let profit: Double
    public let marketValue: Double

    public init(idPosition: Int, profit: Double, marketValue: Double) {
        self.idPosition = idPosition
        self.profit = profit
        self.marketValue = marketValue
    }
}

public struct Trade: Equatable, Sendable {
    public let idPosition: Int
    public let symbolKey: String
    public let isOpen: Bool

    public init(idPosition: Int, symbolKey: String, isOpen: Bool) {
        self.idPosition = idPosition
        self.symbolKey = symbolKey
        self.isOpen = isOpen
    }
}

public struct Instrument: Equatable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

public enum XTBEvent: Equatable, Sendable {
    case loginResult([XTBAccount])
    case balance(TotalBalance)
    case tradeProfit(TradeProfit)
    case trade(Trade)
    case instruments([Instrument])
    case requestFailed(reqId: String, status: Int)
}

/// Decodes one WebSocket message. Shapes are loose, so anything unknown or missing a
/// required field is skipped; this never throws.
public func decodeEvents(_ message: Data) -> [XTBEvent] {
    guard let json = try? JSONSerialization.jsonObject(with: message) else { return [] }
    let envelopes = (json as? [Any])?.compactMap { $0 as? [String: Any] } ?? [json as? [String: Any]].compactMap { $0 }
    return envelopes.flatMap(decodeEnvelope)
}

/// Row `state` the server uses when a row is removed.
private let deletedRowState = 2

private func decodeEnvelope(_ envelope: [String: Any]) -> [XTBEvent] {
    // A reply to our request: status 0 is success. Pushed events carry no reqId.
    if let reqId = envelope["reqId"] as? String, let status = envelope["status"] as? Int, status != 0 {
        return [.requestFailed(reqId: reqId, status: status)]
    }
    var events: [XTBEvent] = []
    for response in envelope["response"] as? [[String: Any]] ?? [] {
        if let login = response["xloginresult"] as? [String: Any] {
            events += decodeLogin(login).map { [.loginResult($0)] } ?? []
        }
        let rows = (response["element"] as? [String: Any])?["elements"] as? [[String: Any]] ?? []
        events += decodeRows(rows)
    }
    let pushed = (envelope["events"] as? [[String: Any]] ?? []).compactMap { $0["row"] as? [String: Any] }
    events += decodeRows(pushed)
    return events
}

private func decodeLogin(_ login: [String: Any]) -> [XTBAccount]? {
    guard let list = login["accountList"] as? [[String: Any]] else { return nil }
    return list.compactMap { entry in
        guard let id = entry["wtAccountId"] as? [String: Any],
              let accountNo = id["accountNo"] as? String,
              let endpoint = id["endpointID"] as? String,
              let currency = entry["currency"] as? String,
              let isArchived = entry["isArchived"] as? Bool else { return nil }
        return XTBAccount(accountNo: accountNo, endpoint: endpoint, currency: currency, isArchived: isArchived)
    }
}

/// Symbols in one message are grouped into a single `.instruments` event.
private func decodeRows(_ rows: [[String: Any]]) -> [XTBEvent] {
    var events: [XTBEvent] = []
    var instruments: [Instrument] = []
    for row in rows {
        guard let value = row["value"] as? [String: Any] else { continue }
        if let b = value["xtotalbalance"] as? [String: Any] {
            if let accountNo = (b["aid"] as? [String: Any])?["accountNo"] as? String,
               let equity = b["totalEquity"] as? Double, let profit = b["profit"] as? Double {
                events.append(.balance(TotalBalance(accountNo: accountNo, equity: equity, profit: profit)))
            }
        } else if let p = value["xtradeprofit"] as? [String: Any] {
            if let id = p["idPosition"] as? Int, let profit = p["profit"] as? Double,
               let marketValue = p["marketValue"] as? Double {
                events.append(.tradeProfit(TradeProfit(idPosition: id, profit: profit, marketValue: marketValue)))
            }
        } else if let t = value["xcfdtrade"] as? [String: Any] {
            if let id = t["positionId"] as? Int, let symbol = t["symbol"] as? String {
                let isOpen = (row["state"] as? Int) != deletedRowState
                events.append(.trade(Trade(idPosition: id, symbolKey: symbol, isOpen: isOpen)))
            }
        } else if let s = value["xcfdsymbol"] as? [String: Any] {
            if let key = s["name"] as? String, let name = s["displayName"] as? String {
                instruments.append(Instrument(key: key, name: name))
            }
        }
    }
    if !instruments.isEmpty { events.append(.instruments(instruments)) }
    return events
}
