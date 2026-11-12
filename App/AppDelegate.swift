import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit
import XTBKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static let hideEquityKey = "hideEquityOnHover"
    private static let accountKey = "menuBarAccount"
    /// Set after the saved login was rejected, so the app never retries a bad password on its own.
    private static let loginBlockedKey = "loginBlocked"

    private let model = BarModel()
    private let defaults = UserDefaults.standard
    private let rates = ExchangeRates()
    private var statusItem: StatusItemController!
    private var reader: PageReader?
    /// True while `reader` is a live session that keeps xStation open.
    private var readerIsLive = false
    private var lastSample = Date.distantPast
    private var timer: Timer?
    private var problem: String?
    private var settingsWindow: NSWindow?

    /// An account number, or `SharedStore.allAccounts` for the sum.
    private var account: String {
        get { defaults.string(forKey: Self.accountKey) ?? SharedStore.allAccounts }
        set { defaults.set(newValue, forKey: Self.accountKey) }
    }


    func applicationDidFinishLaunching(_ notification: Notification) {
        moveHistoryToSharedStore()

        statusItem = StatusItemController(model: model, actions: .init(
            refresh: { [weak self] in self?.refresh(interactive: false) },
            logInInWindow: { [weak self] in self?.refresh(interactive: true) },
            openSettings: { [weak self] in self?.openSettings() },
            statusLine: { [weak self] in self?.statusLine() ?? "" },
            toggleEquityOnHover: { [weak self] in
                guard let self else { return }
                self.model.showEquityOnHover.toggle()
                self.defaults.set(!self.model.showEquityOnHover, forKey: Self.hideEquityKey)
            },
            accounts: { [SharedStore.allAccounts] + SharedStore.readAccounts().map(\.accountNo) },
            currentAccount: { [weak self] in self?.account ?? SharedStore.allAccounts },
            setAccount: { [weak self] in self?.account = $0; self?.reload() },
            setRefreshSeconds: { [weak self] seconds in
                guard let self else { return }
                RefreshInterval.seconds = seconds
                Log.write("refresh every \(RefreshInterval.label(RefreshInterval.seconds))")
                // A live session keeps its pace until it ends, so it is ended now; the next
                // session (or the next single read) follows the new setting.
                if self.readerIsLive { self.reader?.stop() } else if self.reader == nil { self.scheduleNext() }
                self.reload()
                WidgetCenter.shared.reloadAllTimelines()
            }))
        model.showEquityOnHover = !defaults.bool(forKey: Self.hideEquityKey)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(interactive: false) }
        }
        try? SMAppService.mainApp.register()

        reload()
        refresh(interactive: false)
    }

    private func statusLine() -> String {
        if reader != nil, !readerIsLive { return "Odświeżanie…" }
        if let problem { return problem }
        guard let snapshot = model.snapshot else { return "Brak danych" }
        return "Dane z " + snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
    }

    /// Re-reads what is on disk into the menu bar item.
    private func reload() {
        let display = Display(store: SharedStore.store(for: account), range: .day, now: Date())
        model.snapshot = display.snapshot
        model.dailyChange = display.dailyChange
        model.stale = display.stale
    }

    /// Earlier builds kept history in Application Support, which the sandboxed widget cannot read.
    /// Moves it once into the shared container; the log stays where it is.
    private func moveHistoryToSharedStore() {
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XTBBar")
        guard old.standardizedFileURL != SharedStore.directory.standardizedFileURL else { return }
        for name in ["samples.jsonl", "snapshot.json"] {
            let from = old.appendingPathComponent(name), to = SharedStore.directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else { continue }
            do { try FileManager.default.moveItem(at: from, to: to) } catch { Log.write("could not move \(name): \(error.localizedDescription)") }
        }
    }

    /// Builds before per-account history kept one account's history in the container's root.
    /// Hands it to the account with the same currency, if exactly one has it and has no history yet.
    private func adoptSingleAccountHistory(_ parts: [String: Snapshot]) {
        let root = SampleStore(directory: SharedStore.directory)
        guard let old = root.readSnapshot() else { return }
        let matching = parts.filter { $0.value.currency == old.currency }.map(\.key)
        guard matching.count == 1 else { return }
        let folder = SharedStore.folder(for: matching[0])
        for name in ["samples.jsonl", "snapshot.json"] {
            let from = SharedStore.directory.appendingPathComponent(name), to = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }
            do { try FileManager.default.moveItem(at: from, to: to) } catch { Log.write("could not move \(name): \(error.localizedDescription)") }
        }
        try? FileManager.default.removeItem(at: SharedStore.directory.appendingPathComponent("snapshot.json"))
    }

    private func refresh(interactive: Bool) {
        guard reader == nil else { return }
        let reader = PageReader()
        self.reader = reader
        let live: TimeInterval? = !interactive && RefreshInterval.isLive ? TimeInterval(RefreshInterval.seconds) : nil
        readerIsLive = live != nil
        if interactive { defaults.set(false, forKey: Self.loginBlockedKey) }
        let mayLogIn = !interactive && !defaults.bool(forKey: Self.loginBlockedKey)
        Task {
            let outcome = await reader.run(interactive: interactive, credentials: mayLogIn ? {
                guard let username = Keychain.username(), let password = Keychain.password(for: username) else { return nil }
                return (username, password)
            } : nil, live: live, onUpdate: { [weak self] parts in
                Task { @MainActor in
                    guard let self else { return }
                    let rates = await self.rates.rates(for: Set(parts.values.map(\.currency)))
                    self.problem = nil
                    if self.save(parts, rates: rates) { WidgetCenter.shared.reloadAllTimelines() }
                    self.reload()
                }
            })
            var rates: [String: Double] = [:]
            if case .snapshots(let parts) = outcome {
                rates = await self.rates.rates(for: Set(parts.values.map(\.currency)))
            }
            self.reader = nil
            self.readerIsLive = false
            self.handle(outcome, rates: rates)
            self.scheduleNext()
        }
    }

    private func handle(_ outcome: RefreshOutcome, rates: [String: Double]) {
        switch outcome {
        case .snapshots(let parts):
            problem = nil
            defaults.set(false, forKey: Self.loginBlockedKey)
            save(parts, rates: rates)
        case .loginRequired:
            problem = "Wymaga logowania"
        case .loginRejected:
            defaults.set(true, forKey: Self.loginBlockedKey)
            problem = "Logowanie odrzucone. Zaloguj się w oknie"
        case .codeRequired:
            // Every automatic login sends another SMS, so stop until the owner logs in by hand.
            defaults.set(true, forKey: Self.loginBlockedKey)
            problem = "XTB prosi o kod SMS. Zaloguj się w oknie"
        case .failed(let message):
            problem = message
        }
        if problem != nil {
            for choice in [SharedStore.allAccounts] + SharedStore.readAccounts().map(\.accountNo) {
                let store = SharedStore.store(for: choice)
                if var last = store.readSnapshot(), last.connected {
                    last.connected = false
                    try? store.writeSnapshot(last)
                }
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        reload()
    }

    /// Writes each account's snapshot and the sum. A history sample is added only when one is due,
    /// so live updates every few seconds do not grow the history. Returns whether one was added.
    @discardableResult
    private func save(_ parts: [String: Snapshot], rates: [String: Double]) -> Bool {
        guard !parts.isEmpty else { return false }
        adoptSingleAccountHistory(parts)
        var known = SharedStore.readAccounts().filter { parts[$0.accountNo] == nil }
        known += parts.map { AccountInfo(accountNo: $0.key, currency: $0.value.currency) }
        SharedStore.writeAccounts(known.sorted { $0.accountNo < $1.accountNo })
        var toWrite = parts
        if let sum = Snapshot.combined(Array(parts.values), in: "PLN", rates: rates) {
            toWrite[SharedStore.allAccounts] = sum
        } else {
            Log.write("sum of accounts skipped: no exchange rate")
        }
        let sampleDue = Date().timeIntervalSince(lastSample) >= RefreshInterval.sampleSeconds - 30
        if sampleDue { lastSample = Date() }
        for (choice, snapshot) in toWrite {
            let store = SharedStore.store(for: choice)
            try? store.writeSnapshot(snapshot)
            if sampleDue { try? store.append(Sample(t: snapshot.updatedAt, equity: snapshot.equity, profit: snapshot.profit)) }
        }
        return sampleDue
    }

    private func scheduleNext() {
        timer?.invalidate()
        // Live: the next session starts right after one ends, unless it ended on a problem.
        let next = RefreshInterval.isLive
            ? Date().addingTimeInterval(problem == nil ? 2 : 5 * 60)
            : nextSampleDate(after: Date(), every: TimeInterval(RefreshInterval.seconds))
        timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh(interactive: false) }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView { [weak self] in
                self?.settingsWindow?.close()
                self?.defaults.set(false, forKey: Self.loginBlockedKey)
                self?.refresh(interactive: false)
            }))
            window.title = "XTBBar: login"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
