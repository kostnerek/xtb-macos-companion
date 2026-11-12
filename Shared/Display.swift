import Foundation
import XTBKit

/// What the menu bar and the widget show, worked out from the files the app writes.
struct Display {
    static var staleAfter: TimeInterval { RefreshInterval.staleAfter }

    let snapshot: Snapshot?
    let chart: [[Double]]
    let dailyChange: Double?
    /// True when the numbers are not from a recent successful refresh.
    let stale: Bool

    init(store: SampleStore, range: ChartRange, now: Date) {
        let snapshot = store.readSnapshot()
        self.snapshot = snapshot
        // A break in the chart only where at least two refreshes in a row are missing.
        let maxGap = max(45 * 60, 3 * RefreshInterval.sampleSeconds)
        chart = segments(store.samples(in: range, now: now), maxGap: maxGap).map { $0.map(\.profit) }
        dailyChange = snapshot.flatMap {
            XTBKit.dailyChange(currentProfit: $0.profit, samples: store.samples(in: .all, now: now), now: now, calendar: .current)
        }
        stale = snapshot.map { !$0.connected || now.timeIntervalSince($0.updatedAt) > Self.staleAfter } ?? true
    }
}

/// How often the app refreshes, chosen in the menu. Kept in the shared container because the
/// widget needs it too, to know when data is stale. Between 5 and 60 minutes every refresh opens
/// xStation, reads it (about 20 seconds) and closes it again. Below a minute ("live") xStation stays
/// open in the background instead and the numbers are re-read from it every 10 or 30 seconds.
enum RefreshInterval {
    static let choices = [10, 30, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 60 * 60]
    static let standard = 15 * 60
    /// In live mode history is still sampled at this pace, so the file does not grow every few seconds.
    static let liveSampleSeconds: TimeInterval = 15 * 60

    private struct Settings: Codable { var refreshSeconds: Int }
    private static var url: URL { SharedStore.directory.appendingPathComponent("settings.json") }

    static var seconds: Int {
        get {
            let stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }?.refreshSeconds
            return stored.flatMap { choices.contains($0) ? $0 : nil } ?? standard
        }
        set {
            try? JSONEncoder().encode(Settings(refreshSeconds: choices.contains(newValue) ? newValue : standard))
                .write(to: url, options: .atomic)
        }
    }

    static var isLive: Bool { seconds < 60 }
    /// How often a history sample is written.
    static var sampleSeconds: TimeInterval { isLive ? liveSampleSeconds : TimeInterval(seconds) }
    /// A snapshot older than this is shown as stale.
    static var staleAfter: TimeInterval { isLive ? 2 * 60 : TimeInterval(seconds) + 5 * 60 }

    static func label(_ seconds: Int) -> String { seconds < 60 ? "\(seconds) s (na żywo)" : "\(seconds / 60) min" }
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
