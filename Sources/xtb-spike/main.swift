// Exploratory spike: logs in to XTB the way the xStation 5 web app does and reports
// what the data stream looks like. Read-only. Never prints secrets.
import Foundation
import Security

setvbuf(stdout, nil, _IONBF, 0)

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: xtb-spike <login> [--record <dir>] [--hold <minutes>]")
    exit(2)
}
let login = args[1]
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let recordDir = option("--record").map { URL(fileURLWithPath: $0) }
let holdSeconds = (Double(option("--hold") ?? "1") ?? 1) * 60

// MARK: Keychain

let service = "xtb-widget"
func keychainRead(_ account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
func keychainWrite(_ value: String, _ account: String) {
    let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    SecItemAdd(add as CFDictionary, nil)
}

guard let password = keychainRead(login) else {
    print("no password in keychain for this login; run: security add-generic-password -s xtb-widget -a \"<login>\" -w")
    exit(1)
}
let fingerprint: String = {
    if let f = keychainRead("fingerprint") { return f }
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let f = bytes.map { String(format: "%02x", $0) }.joined()
    keychainWrite(f, "fingerprint")
    return f
}()

// MARK: Scrubbing

var secrets: [String: String] = [password: "<PASSWORD>", login: "user@example.com", fingerprint: "<FINGERPRINT>"]
func scrub(_ text: String) -> String {
    var t = text
    for (secret, placeholder) in secrets where !secret.isEmpty { t = t.replacingOccurrences(of: secret, with: placeholder) }
    return t
}
func scrubPersonal(_ value: Any) -> Any {
    if var dict = value as? [String: Any] {
        for (k, v) in dict {
            if ["userData", "userID"].contains(k), let inner = v as? [String: Any] {
                dict[k] = inner.mapValues { $0 is String ? "x" as Any : $0 }
            } else if ["login", "username"].contains(k), v is String {
                dict[k] = "x"
            } else {
                dict[k] = scrubPersonal(v)
            }
        }
        return dict
    }
    if let arr = value as? [Any] { return arr.map(scrubPersonal) }
    return value
}

var recorded = Set<String>()
func record(_ name: String, _ object: Any) {
    guard let dir = recordDir, !recorded.contains(name) else { return }
    recorded.insert(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let data = try? JSONSerialization.data(withJSONObject: scrubPersonal(object), options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return }
    try? scrub(text).write(to: dir.appendingPathComponent(name + ".json"), atomically: true, encoding: .utf8)
    print("  recorded \(name).json")
}

// MARK: CAS login

let http = URLSession(configuration: .ephemeral)
func post(_ path: String, _ body: [String: Any]) async throws -> (status: Int, json: [String: Any]) {
    var req = URLRequest(url: URL(string: "https://xstation.xtb.com/signon" + path)!)
    req.httpMethod = "POST"
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "Time-Zone")
    let (data, resp) = try await http.data(for: req)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return ((resp as? HTTPURLResponse)?.statusCode ?? -1, json)
}
func describe(_ json: [String: Any]) -> String {
    json.keys.sorted().map { k in
        let v = json[k]!
        if let s = v as? String { return ["ticket", "serviceTicket"].contains(k) ? "\(k)=<\(s.count) chars>" : "\(k)=\(scrub(s))" }
        return "\(k)=\(v)"
    }.joined(separator: ", ")
}

print("== CAS: tickets (single attempt)")
let ticketResp = try await post("/v2/tickets", ["username": login, "password": password, "fingerprint": fingerprint, "rememberMe": true])
print("  status \(ticketResp.status): \(describe(ticketResp.json))")
guard ticketResp.json["success"] as? Bool == true, let tgt = ticketResp.json["ticket"] as? String else {
    print("  login not successful, stopping without retry")
    exit(1)
}
secrets[tgt] = "<TICKET>"
for c in http.configuration.httpCookieStorage?.cookies ?? [] {
    secrets[c.value] = "<COOKIE>"
    print("  cookie \(c.name) domain=\(c.domain) path=\(c.path) expires=\(c.expiresDate.map { "\($0)" } ?? "session") valueLength=\(c.value.count) equalsTicket=\(c.value == tgt)")
}

print("== CAS: serviceTicket")
let stResp = try await post("/v2/serviceTicket", ["service": "xapi5"])
print("  status \(stResp.status): \(describe(stResp.json))")
guard let serviceTicket = stResp.json["serviceTicket"] as? String else { exit(1) }
secrets[serviceTicket] = "<SERVICE_TICKET>"

// MARK: Socket

var wsRequest = URLRequest(url: URL(string: "wss://api5reala.x-station.eu/v1/xstation")!)
wsRequest.setValue("https://xstation5.xtb.com", forHTTPHeaderField: "Origin")
let ws = http.webSocketTask(with: wsRequest)
ws.maximumMessageSize = 64 * 1024 * 1024
ws.resume()
let started = Date()
func elapsed() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }

var counter = 0
func send(_ name: String, _ core: [String: Any]) {
    counter += 1
    let reqId = "\(name)_\(Int(Date().timeIntervalSince1970 * 1000))_\(counter)"
    let message: [String: Any] = ["reqId": reqId, "command": [["CoreAPI": core]]]
    let data = try! JSONSerialization.data(withJSONObject: message)
    ws.send(.string(String(data: data, encoding: .utf8)!)) { error in
        if let error { print("\(elapsed()) send \(name) failed: \(error.localizedDescription)") }
    }
    print("\(elapsed()) -> \(name)")
}

var eventCounts: [String: Int] = [:]
var rawShown = 0

func handle(_ item: Any) {
    guard let msg = item as? [String: Any] else {
        print("\(elapsed()) <- non-object frame item: \(scrub("\(item)").prefix(80))")
        return
    }
    if let reqId = msg["reqId"] as? String {
        let name = String(reqId.split(separator: "_").first ?? "")
        let status = msg["status"] as? Int ?? -1
        let response = msg["response"] as? [[String: Any]] ?? []
        let kinds = response.flatMap { $0.keys }
        var count = 0
        if let elements = (response.first?["element"] as? [String: Any])?["elements"] as? [[String: Any]] {
            count = elements.count
            if let first = elements.first, let value = first["value"] as? [String: Any] {
                print("\(elapsed()) <- \(name) status=\(status) elements=\(count) kind=\(value.keys.sorted()) states=\(Set(elements.compactMap { $0["state"] as? Int }).sorted())")
            }
        } else {
            print("\(elapsed()) <- \(name) status=\(status) response=\(kinds) keys=\(msg.keys.sorted())")
        }
        record("resp_" + name, msg)
        if name == "registerClientInfo" {
            send("loginWithServiceTicket", ["endpoint": "", "logonWithServiceTicket": ["serviceTicket": serviceTicket]])
        }
        if name == "loginWithServiceTicket", let result = response.first?["xloginresult"] as? [String: Any] {
            let accounts = result["accountList"] as? [[String: Any]] ?? []
            print("  endpointList=\(result["endpointList"] ?? "-") accounts=\(accounts.count)")
            for (i, acc) in accounts.enumerated() {
                let wt = acc["wtAccountId"] as? [String: Any] ?? [:]
                let no = wt["accountNo"].map { "\($0)" } ?? ""
                let endpoint = wt["endpointID"] as? String ?? ""
                secrets[no] = "1000000\(i + 1)"
                print("  account #\(i + 1): endpoint=\(endpoint) currency=\(acc["currency"] ?? "-") archived=\(acc["isArchived"] ?? "-") trial=\(acc["isTrial"] ?? "-") type=\(acc["endpointType"] ?? "-") keys=\(acc.keys.sorted())")
                guard acc["isArchived"] as? Bool != true else { continue }
                let accountId = "\(endpoint)_\(no)"
                for (label, eid) in [("getAndSubscribeTotalBalance", 1043), ("getAndSubscribeTradeProfit", 1038), ("getAndSubscribeTradeRecord", 1)] {
                    send(label, ["endpoint": endpoint, "accountId": accountId, "getAndSubscribeElement": ["eid": eid]])
                }
                if i == 0 {
                    send("getAllSymbolsLight", ["endpoint": endpoint, "accountId": accountId,
                                                "getElement": ["eid": 3, "fields": ["name", "displayName", "quoteId", "idAssetClass", "groupId", "instrumentId"]]])
                }
            }
        }
        return
    }
    if let events = msg["events"] as? [[String: Any]] {
        for ev in events {
            let element = ev["element"].map { "\($0)" } ?? "?"
            let row = ev["row"] as? [String: Any] ?? [:]
            let value = row["value"] as? [String: Any] ?? [:]
            let key = "\(ev["scope"] ?? "?")/\(element)/\(value.keys.sorted().joined(separator: ","))/state=\(row["state"] ?? "?")"
            eventCounts[key, default: 0] += 1
            if eventCounts[key] == 1 {
                print("\(elapsed()) <- first event \(key)")
                record("event_\(element)_state\(row["state"] ?? "x")", msg)
                if let b = value["xtotalbalance"] as? [String: Any] {
                    print("  balance fields: " + b.keys.sorted().filter { $0 != "aid" }.map { "\($0)=\(b[$0]!)" }.joined(separator: " "))
                }
            }
        }
        return
    }
    print("\(elapsed()) <- other message keys=\(msg.keys.sorted())")
    record("other_\(msg.keys.sorted().joined(separator: "_"))", msg)
}

func receiveLoop() {
    ws.receive { result in
        switch result {
        case .failure(let error):
            print("\(elapsed()) socket closed: code=\(ws.closeCode.rawValue) reason=\(ws.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? "-") error=\(error.localizedDescription)")
            print("event counts: \(eventCounts)")
            exit(0)
        case .success(let message):
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8) ?? "<binary \(d.count) bytes>"
            @unknown default: text = ""
            }
            if rawShown < 3 {
                rawShown += 1
                print("\(elapsed()) raw frame head: \(scrub(String(text.prefix(70))))")
            }
            if let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
                if let arr = parsed as? [Any] { arr.forEach(handle) } else { handle(parsed) }
            } else {
                print("\(elapsed()) <- non-JSON frame (\(text.count) chars): \(scrub(String(text.prefix(60))))")
            }
            receiveLoop()
        }
    }
}
receiveLoop()

send("registerClientInfo", ["endpoint": "", "registerClientInfo": ["clientInfo": [
    "appName": "xStation5 | xStation 5", "appVersion": "2.111.0", "appBuildNumber": "",
    "device": "macOS 10.15.7 / Chrome 156.0", "osVersion": "",
    "comment": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36",
    "apiVersion": "2.73.0", "osType": 0, "deviceType": 1,
]]])

// WebSocket-level ping every 30 s so we can tell whether the server answers and how long it tolerates us.
Task {
    while true {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        let sent = Date()
        ws.sendPing { error in
            print("\(elapsed()) ws ping \(error.map { "failed: \($0.localizedDescription)" } ?? String(format: "pong after %.0f ms", Date().timeIntervalSince(sent) * 1000))")
        }
    }
}

try await Task.sleep(nanoseconds: UInt64(holdSeconds * 1_000_000_000))
print("\(elapsed()) hold finished, socket still open: \(ws.state == .running)")
print("event counts: \(eventCounts)")
ws.cancel(with: .normalClosure, reason: nil)
exit(0)
