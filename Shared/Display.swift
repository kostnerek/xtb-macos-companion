import Foundation
import XTBKit

/// What the menu bar and the widget show, worked out from the files the app writes.
struct Display {
    /// A snapshot older than this is shown as stale (one missed refresh plus slack).
    static let staleAfter: TimeInterval = 20 * 60

    let snapshot: Snapshot?
    let chart: [[Double]]
    let dailyChange: Double?
    /// True when the numbers are not from a recent successful refresh.
    let stale: Bool

    init(store: SampleStore, range: ChartRange, now: Date) {
        let snapshot = store.readSnapshot()
        self.snapshot = snapshot
        chart = segments(store.samples(in: range, now: now), maxGap: 45 * 60).map { $0.map(\.profit) }
        dailyChange = snapshot.flatMap {
            XTBKit.dailyChange(currentProfit: $0.profit, samples: store.samples(in: .all, now: now), now: now, calendar: .current)
        }
        stale = snapshot.map { !$0.connected || now.timeIntervalSince($0.updatedAt) > Self.staleAfter } ?? true
    }
}

/// An account the app has seen, listed in the menu and in "Edit Widget".
struct AccountInfo: Codable, Equatable {
    let accountNo: String
    let currency: String

    var label: String { accountNo == SharedStore.ikze ? "IKZE (\(currency))" : "Rachunek …\(accountNo.suffix(3)) (\(currency))" }
}

/// The folder both the app and the widget read: the App Group container. Its identifier comes
/// from Info.plist (`XTBAppGroup`), where the build fills in the signing team's prefix.
/// Each account keeps its own history in `accounts/<number>`; `accounts/all` holds the sum.
enum SharedStore {
    /// The choice that means "all accounts summed in PLN".
    static let allAccounts = "all"
    static let allAccountsLabel = "Wszystkie konta (PLN)"
    /// IKZE has no trading account number in xStation's account list, so it gets this key.
    static let ikze = "ikze"

    static let directory: URL = {
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XTBBar")
        let directory = (Bundle.main.object(forInfoDictionaryKey: "XTBAppGroup") as? String)
            .flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) } ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static func folder(for choice: String) -> URL {
        let folder = directory.appendingPathComponent("accounts").appendingPathComponent(choice)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func store(for choice: String) -> SampleStore { SampleStore(directory: folder(for: choice)) }

    private static var accountsURL: URL { directory.appendingPathComponent("accounts.json") }

    static func readAccounts() -> [AccountInfo] {
        (try? Data(contentsOf: accountsURL)).flatMap { try? JSONDecoder().decode([AccountInfo].self, from: $0) } ?? []
    }

    static func writeAccounts(_ accounts: [AccountInfo]) {
        try? JSONEncoder().encode(accounts).write(to: accountsURL, options: .atomic)
    }

    static func label(for choice: String) -> String {
        choice == allAccounts ? allAccountsLabel : readAccounts().first { $0.accountNo == choice }?.label ?? "Rachunek …\(choice.suffix(3))"
    }
}
