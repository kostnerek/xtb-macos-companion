import AppKit
import Combine
import SwiftUI
import XTBKit

/// Lets clicks fall through to the status bar button underneath, which opens the menu.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns the menu bar item: draws `StatusItemView`, and on click shows a menu with the totals,
/// each account and every position, followed by the settings.
@MainActor
final class StatusItemController: NSResponder, NSMenuDelegate {
    struct Actions {
        var refresh: () -> Void
        var logInInWindow: () -> Void
        var openSettings: () -> Void
        var statusLine: () -> String
        var toggleEquityOnHover: () -> Void
        var accounts: () -> [String]
        var currentAccount: () -> String
        var setAccount: (String) -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: BarModel
    private let actions: Actions
    private var hosting: NSView?
    private var subscription: AnyCancellable?

    init(model: BarModel, actions: Actions) {
        self.model = model
        self.actions = actions
        super.init()
        guard let button = item.button else { return }
        let hosting = PassthroughHostingView(rootView: StatusItemView(model: model))
        button.addSubview(hosting)
        self.hosting = hosting
        button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                              owner: self, userInfo: nil))
        // Lets macOS remember where the owner Cmd-dragged the item.
        item.autosaveName = "XTBBar"
        let menu = NSMenu()
        menu.delegate = self
        // Rows of numbers stay in normal colours instead of the grey of disabled items.
        menu.autoenablesItems = false
        item.menu = menu
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resize() }
        }
        resize()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func resize() {
        guard let hosting, let button = item.button else { return }
        // The button is shorter than the menu bar on screens with a camera notch; the item draws
        // over the bar's full height so three small lines fit.
        let height = max(button.window?.frame.height ?? 0, button.bounds.height)
        if model.barHeight != height { model.barHeight = height }
        let width = hosting.fittingSize.width
        item.length = width
        hosting.frame = NSRect(x: 0, y: (button.bounds.height - height) / 2, width: width, height: height)
    }

    override func mouseEntered(with event: NSEvent) { model.hovered = true }
    override func mouseExited(with event: NSEvent) { model.hovered = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: actions.statusLine(), action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        addOverview(to: menu)
        menu.addItem(item("Odśwież teraz", #selector(refresh)))
        menu.addItem(item("Zaloguj się w oknie…", #selector(logIn)))
        let accounts = NSMenuItem(title: "Konto", action: nil, keyEquivalent: "")
        accounts.submenu = NSMenu()
        for choice in actions.accounts() {
            let entry = item(SharedStore.label(for: choice), #selector(pickAccount(_:)))
            entry.representedObject = choice
            entry.state = choice == actions.currentAccount() ? .on : .off
            accounts.submenu?.addItem(entry)
        }
        menu.addItem(accounts)
        let equity = item("Wartość konta po najechaniu", #selector(toggleEquity))
        equity.state = model.showEquityOnHover ? .on : .off
        menu.addItem(equity)
        menu.addItem(item("Login i hasło…", #selector(settings)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Zakończ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// Totals of the chosen account; for the sum also each account; then every position.
    private func addOverview(to menu: NSMenu) {
        guard let snapshot = model.snapshot else { return }
        let currency = snapshot.currency
        let choice = actions.currentAccount()
        menu.addItem(row(SharedStore.label(for: choice), bold: true))
        menu.addItem(row("Zysk", Money.signed(snapshot.profit, currency), Money.percent(snapshot.profitPercent), color: snapshot.profit))
        if let change = model.dailyChange {
            menu.addItem(row("Dziś", "", Money.signed(change, currency), color: change))
        }
        menu.addItem(row("Wartość", "", Money.plain(snapshot.equity, currency)))
        if choice == SharedStore.allAccounts {
            menu.addItem(.separator())
            for account in SharedStore.readAccounts() {
                guard let part = SharedStore.store(for: account.accountNo).readSnapshot() else { continue }
                menu.addItem(row(account.label, Money.plain(part.equity, part.currency), Money.signed(part.profit, part.currency), color: part.profit))
            }
        }
        if !snapshot.positions.isEmpty {
            menu.addItem(.separator())
            menu.addItem(row("Pozycje", "Wartość", "Zysk", bold: true))
            for position in snapshot.positions {
                menu.addItem(row(position.name, Money.plain(position.value, currency), Money.percent(position.profitPercent), color: position.profit))
            }
        }
        menu.addItem(.separator())
    }

    /// One line of numbers: a name, then up to two right-aligned columns. The last column takes
    /// the colour of `color`'s sign.
    private func row(_ name: String, _ first: String = "", _ second: String = "", color: Double? = nil, bold: Bool = false) -> NSMenuItem {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 300), NSTextTab(textAlignment: .right, location: 390)]
        let font = bold ? NSFont.boldSystemFont(ofSize: 13) : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let title = NSMutableAttributedString(string: "\(name)\t\(first)\t", attributes: [.font: font, .paragraphStyle: style])
        let tint: NSColor = color.map { $0 < 0 ? .systemRed : .systemGreen } ?? .labelColor
        title.append(NSAttributedString(string: second, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: tint]))
        let entry = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        entry.attributedTitle = title
        return entry
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        return entry
    }

    @objc private func refresh() { actions.refresh() }
    @objc private func logIn() { actions.logInInWindow() }
    @objc private func settings() { actions.openSettings() }
    @objc private func toggleEquity() { actions.toggleEquityOnHover() }
    @objc private func pickAccount(_ sender: NSMenuItem) {
        if let choice = sender.representedObject as? String { actions.setAccount(choice) }
    }
}
