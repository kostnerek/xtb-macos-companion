import AppKit
import WebKit
import XTBKit

enum RefreshOutcome {
    /// One snapshot per account that answered, keyed by account number.
    case snapshots([String: Snapshot])
    /// The page asks for a login and there is nothing to log in with.
    case loginRequired
    /// The saved login was submitted once and the page still asks for a login (wrong password, 2FA…).
    case loginRejected
    /// The password was accepted and XTB asks for the code it sent by SMS.
    case codeRequired
    case failed(String)
}

/// One refresh: loads the real xStation in a web view, listens to the data the page receives,
/// and returns a snapshot per account. The page streams only the account it has open, so after
/// one account settles the reader picks the next one in the page's account switcher. The web view is thrown away afterwards so it holds no memory between
/// refreshes. The page logs in and keeps its own session; nothing here talks to XTB directly.
@MainActor
final class PageReader: NSObject, WKScriptMessageHandler, NSWindowDelegate, WKNavigationDelegate {
    typealias Credentials = (username: String, password: String)

    private static let pageURL = URL(string: "https://xstation5.xtb.com/")!
    /// How long to keep collecting after the first balance, so positions and names arrive too.
    private static let settleSeconds: TimeInterval = 6
    private static let hiddenTimeout: TimeInterval = 90
    /// How long a pension account's view may take to show its numbers before it is skipped.
    private static let pensionTimeout: TimeInterval = 20
    /// A live session ends after this long, so the next one reads every account afresh.
    private static let liveCycle: TimeInterval = 15 * 60
    /// After switching back to the złoty account, how long to let the page load.
    private static let returnSeconds: TimeInterval = 12
    private static let interactiveTimeout: TimeInterval = 600
    private static let loginVerdictSeconds: TimeInterval = 25

    /// Forwards the messages the page's socket worker delivers, limited to the kinds we read.
    private static let tapScript = """
    (function () {
      window.__xtbErrors = [];
      var note = function (text) { if (window.__xtbErrors.length < 8) { window.__xtbErrors.push(String(text).slice(0, 160)); } };
      window.addEventListener('error', function (e) { note((e.message || 'resource error') + ' @ ' + String(e.filename || (e.target && (e.target.src || e.target.href)) || '').slice(-60)); }, true);
      window.addEventListener('unhandledrejection', function (e) { note('rejection: ' + (e.reason && (e.reason.message || e.reason))); });
      var want = /xtotalbalance|xtradeprofit|xcfdtrade|xcfdsymbol|xloginresult/;
      var Original = window.Worker;
      if (!Original || window.__xtbNoTap) { return; }
      window.__xtbWorkers = 0;
      window.Worker = function (url, options) {
        var worker = new Original(url, options);
        window.__xtbWorkers += 1;
        worker.addEventListener('message', function (event) {
          try {
            var text = typeof event.data === 'string' ? event.data : JSON.stringify(event.data);
            if (want.test(text)) { window.webkit.messageHandlers.xtb.postMessage(text); }
          } catch (e) {}
        });
        return worker;
      };
      window.Worker.prototype = Original.prototype;
    })();
    """

    /// 'code' when XTB asks for the SMS code, 'login' when it shows the login form, '' otherwise.
    /// Mutes every audio or video element before it plays and keeps Web Audio suspended.
    private static let muteScript = """
    (function () {
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () { this.muted = true; this.volume = 0; return play.apply(this, arguments); };
      ['AudioContext', 'webkitAudioContext'].forEach(function (name) {
        var Original = window[name];
        if (!Original) { return; }
        var Muted = function (options) { var context = new Original(options); context.suspend(); context.resume = function () { return Promise.resolve(); }; return context; };
        Muted.prototype = Original.prototype;
        window[name] = Muted;
      });
    })();
    """

    private static let loginState = """
    (function () {
      var box = document.querySelector('.xs-login-2fa-box');
      if ((box && box.offsetParent !== null) || /Kod weryfikacyjny/.test(document.body ? document.body.innerText : '')) { return 'code'; }
      var p = document.querySelector('input[type=password]');
      return p && p.offsetParent !== null ? 'login' : '';
    })()
    """

    /// What the page looked like when a refresh gave up. Page text only, no field values.
    private static let pageDiagnostics = """
    (function () {
      return JSON.stringify({
        title: document.title, path: location.host + location.pathname, ready: document.readyState,
        workers: window.__xtbWorkers, inputs: document.querySelectorAll('input').length,
        passwordFields: document.querySelectorAll('input[type=password]').length,
        frames: document.querySelectorAll('iframe').length, hidden: document.hidden,
        alias: (function () { try { return typeof getBrowserAlias === 'function' ? String(getBrowserAlias()) : 'n/a'; } catch (e) { return 'threw ' + e.message; } })(),
        allowed: (function () { try { return JSON.stringify(window.allowedPlatforms).slice(0, 300); } catch (e) { return 'n/a'; } })(),
        errors: window.__xtbErrors, agent: navigator.userAgent, bodyChildren: document.body ? document.body.children.length : -1,
        text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 200)
      });
    })()
    """

    private static let submitLogin = """
    var pass = document.querySelector('input[type=password]');
    if (!pass) { return 'noform'; }
    var form = pass.closest('form') || document;
    var set = function (el, value) {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    var user = form.querySelector('input[type=email], input[type=text], input:not([type])');
    if (user) { set(user, username); }
    set(pass, password);
    // xStation's button is <input type=button class="xs-btn xs-btn-ok-login" value="Login">.
    var button = form.querySelector('.xs-btn-ok-login, button[type=submit], input[type=submit]');
    if (!button) { return 'nobutton'; }
    button.click();
    return 'submitted';
    """

    private var webView: WKWebView?
    private var window: NSWindow?
    private var timer: Timer?
    private var continuation: CheckedContinuation<RefreshOutcome, Never>?
    private var state = PortfolioState()
    private var started = Date()
    /// When the balance of `current` first arrived; nil while waiting for the next account.
    private var firstData: Date?
    private var current: String?
    private var collected: Set<String> = []
    private var pensionsTried = false
    /// Pension accounts still to open in this pass.
    private var pensionQueue: [PensionAccount] = []
    /// The pension account whose view was opened and is being read, and since when.
    private var pensionOpen: (account: PensionAccount, since: Date)?
    private var pensions: [PensionAccount: Snapshot] = [:]
    /// The pension account whose view the page shows; live mode re-reads only this one.
    private var pensionOnScreen: PensionAccount?
    private var loginSubmitted: Date?
    private var interactive = false
    private var received = 0
    private var credentials: (() -> Credentials?)?
    /// The account the page has open.
    private var pageAccount: String?
    /// Live mode: emit every this many seconds and keep the page open; nil for a single read.
    private var live: TimeInterval?
    private var onUpdate: (([String: Snapshot]) -> Void)?
    private var liveSince: Date?
    private var lastEmit = Date.distantPast
    private var returningHome: Date?

    /// - Parameters:
    ///   - interactive: show the page in a window so the owner can log in by hand.
    ///   - credentials: asked at most once, and only if the page shows its login form.
    ///   - live: after reading every account, keep the page open on the złoty account (whose
    ///     data the page streams) and pass fresh snapshots to `onUpdate` every `live` seconds.
    ///     Other accounts keep the values read at the start. Ends after `liveCycle`.
    func run(interactive: Bool, credentials: (() -> Credentials?)?,
             live: TimeInterval? = nil, onUpdate: (([String: Snapshot]) -> Void)? = nil) async -> RefreshOutcome {
        self.interactive = interactive
        self.credentials = credentials
        self.live = interactive ? nil : live
        self.onUpdate = onUpdate
        started = Date()

        let configuration = WKWebViewConfiguration()
        // WKWebView is Safari's engine but leaves the Safari token out of its user agent, and
        // xStation's supported-browser check then fails to recognise it and never starts.
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        // The page plays notification sounds; nothing here should make noise.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let noTap = ProcessInfo.processInfo.environment["XTB_NO_TAP"] != nil
        configuration.userContentController.addUserScript(
            WKUserScript(source: (noTap ? "window.__xtbNoTap = true;" : "") + Self.tapScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        configuration.userContentController.add(self, name: "xtb")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame,
                              styleMask: interactive ? [.titled, .closable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.title = "xStation: zaloguj się"
        window.delegate = self
        if interactive {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // xStation does not start while its page counts as hidden, and macOS reports a
            // transparent or covered window as hidden. So the window is real but one pixel in a
            // screen corner, kept above other windows, with the full-size page clipped inside it.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            container.addSubview(webView)
            window.contentView = container
            window.setFrame(NSRect(x: 0, y: 0, width: 1, height: 1), display: false)
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.level = .floating
            window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
            window.orderFrontRegardless()
        }
        webView.navigationDelegate = self
        self.webView = webView
        self.window = window
        Log.write("refresh started, interactive=\(interactive)")
        webView.load(URLRequest(url: Self.pageURL))

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    /// Ends a session early, keeping whatever was read.
    func stop() {
        finish(.snapshots(allSnapshots(now: Date())))
    }

    private func tick() {
        let now = Date()
        if let back = returningHome, now.timeIntervalSince(back) >= Self.returnSeconds {
            returningHome = nil
            return openPensions()
        }
        if let since = liveSince, let live {
            if now.timeIntervalSince(since) > Self.liveCycle { return finish(.snapshots(allSnapshots(now: now))) }
            if now.timeIntervalSince(lastEmit) >= live {
                lastEmit = now
                refreshPension(now: now)
                onUpdate?(allSnapshots(now: now))
            }
        }
        if let firstData, let current, now.timeIntervalSince(firstData) >= Self.settleSeconds {
            collected.insert(current)
            self.firstData = nil
            self.current = nil
            // Pension account views only load while the złoty account is open, so read them right then.
            if !pensionsTried, state.snapshot(account: current, now: now)?.currency == "PLN" { return openPensions() }
            return nextAccount()
        }
        if now.timeIntervalSince(started) > (interactive ? Self.interactiveTimeout : Self.hiddenTimeout) {
            // An account that never answered should not throw away the ones that did.
            if !collected.isEmpty { return finish(.snapshots(allSnapshots(now: now))) }
            let pending: RefreshOutcome = loginSubmitted == nil ? .failed("xStation nie odpowiedział na czas") : .loginRejected
            webView?.evaluateJavaScript(Self.pageDiagnostics) { [weak self] result, error in
                Log.write("page state at timeout: \(result ?? error?.localizedDescription ?? "-")")
                self?.webView?.takeSnapshot(with: nil) { image, _ in
                    guard let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("XTBBar/timeout.png"))
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.finish(pending)
                }
            }
            started = .distantFuture
            return
        }
        if let open = pensionOpen {
            if now.timeIntervalSince(open.since) > Self.pensionTimeout {
                pensionOpen = (open.account, .distantFuture)
                webView?.evaluateJavaScript(Self.pensionDiagnostics) { [weak self] result, _ in
                    Task { @MainActor in
                        Log.write("\(open.account.label) view did not show its numbers in time: \(result ?? "-")")
                        self?.pensionOpen = nil
                        self?.openNextPension()
                    }
                }
                return
            }
            return readPension(open.account, now: now)
        }
        guard firstData == nil, !interactive else { return }
        webView?.evaluateJavaScript(Self.loginState) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                switch result as? String {
                case "code": self.finish(.codeRequired)
                // A live session that loses its login ends; the next one logs in again.
                case "login" where self.liveSince != nil: self.finish(.snapshots(self.allSnapshots(now: Date())))
                case "login": self.loginFormShown()
                default: break
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("page loaded")
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("page failed to load: \(error.localizedDescription)")
        Task { @MainActor in self.finish(.failed("nie udało się otworzyć xStation")) }
    }

    private func loginFormShown() {
        if loginSubmitted == nil { Log.write("login form shown, saved login available: \(credentials != nil)") }
        if let submitted = loginSubmitted {
            if Date().timeIntervalSince(submitted) > Self.loginVerdictSeconds { finish(.loginRejected) }
            return
        }
        guard let login = credentials?() else { return finish(.loginRequired) }
        loginSubmitted = Date()
        webView?.callAsyncJavaScript(Self.submitLogin,
                                     arguments: ["username": login.username, "password": login.password],
                                     in: nil, in: .page) { [weak self] result in
            Task { @MainActor in
                Log.write("login form submit: \(result)")
                if case .success(let value) = result, (value as? String) == "submitted" { return }
                self?.finish(.failed("nie udało się wypełnić formularza logowania"))
            }
        }
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        let events = decodeEvents(Data(text.utf8))
        Task { @MainActor in
            self.received += 1
            if self.received == 1 { Log.write("first data message from page (\(text.count) chars, \(events.count) events)") }
            events.forEach { self.state.apply($0) }
            if self.firstData == nil, let fresh = self.state.accountsWithBalance.subtracting(self.collected).sorted().first {
                self.current = fresh
                if self.pageAccount == nil { self.pageAccount = fresh }
                self.firstData = Date()
            }
        }
    }

    /// Trading accounts from the socket, plus the pension accounts read from their views.
    private func allSnapshots(now: Date) -> [String: Snapshot] {
        var result = state.snapshots(now: now)
        for (account, snapshot) in pensions { result[account.rawValue] = snapshot }
        return result
    }

    /// Opens the next trading account not read yet; when all are read, finishes or goes live.
    private func nextAccount() {
        guard let next = state.activeAccounts.first(where: { !collected.contains($0) }) else {
            return live == nil ? finish(.snapshots(allSnapshots(now: Date()))) : startLive()
        }
        openAccount(next)
    }

    /// The page streams only the account it has open, so live mode returns to the złoty account
    /// (and its pension account views) before it starts passing on updates.
    private func startLive() {
        started = .distantFuture
        let home = state.activeAccounts.first { state.snapshot(account: $0, now: Date())?.currency == "PLN" }
        if let home, pageAccount != home {
            returningHome = Date()
            return openAccount(home)
        }
        liveSince = Date()
        Log.write("live: page kept open on …\(pageAccount?.suffix(3) ?? "-")")
    }

    /// Pension accounts (IKE, IKZE) are not trading accounts the socket streams; xStation shows each
    /// in its own view, opened from the side bar. Opens them one after another; the last one found
    /// stays on screen.
    private func openPensions() {
        pensionsTried = true
        pensionQueue = PensionAccount.allCases
        openNextPension()
    }

    /// Opens the next pension account in the queue; once the queue is empty, moves on to the next
    /// trading account. An account missing from the side bar is skipped.
    private func openNextPension() {
        guard !pensionQueue.isEmpty else { return nextAccount() }
        let account = pensionQueue.removeFirst()
        let script = """
        (function () {
          var bar = document.querySelector('xs6-home-view_featuresidebar');
          var root = bar && (bar.shadowRoot || bar);
          var label = root && Array.prototype.find.call(root.querySelectorAll('*'), function (e) { return e.children.length === 0 && e.textContent.trim() === '\(account.label)'; });
          if (!label) { return false; }
          label.click();
          return true;
        })()
        """
        webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                guard (result as? Bool) == true else {
                    Log.write("\(account.label) not in the side bar")
                    return self.openNextPension()
                }
                self.pensionOpen = (account, Date())
            }
        }
    }

    /// Text and visible position rows of a pension account's view, or null until a row is on
    /// screen. The numbers are read from them by XTBKit's `pensionSnapshot`.
    private static let pensionScript = """
    (function () {
      var text = [], rows = [];
      (function walk(node) {
        if (node.nodeType === 3) { text.push(node.textContent); return; }
        if (node.nodeType === 1 && /^(STYLE|SCRIPT)$/.test(node.tagName)) { return; }
        if (node.nodeType === 1 && node.tagName === 'TR' && /group-row/.test(node.className) && node.offsetParent !== null) { rows.push(node); }
        if (node.shadowRoot) { walk(node.shadowRoot); }
        Array.prototype.forEach.call(node.childNodes || [], walk);
      })(document.body);
      if (!rows.length) { return null; }
      return JSON.stringify({
        text: text.join(' ').replace(/[\\s\\u00a0]+/g, ' '),
        rows: rows.map(function (row) {
          return row.innerText.split('\\n').map(function (l) { return l.trim(); }).filter(Boolean);
        })
      });
    })()
    """

    /// What a pension account's view looked like when reading it gave up. Labels and row counts only.
    private static let pensionDiagnostics = """
    (function () {
      var text = [], rows = 0;
      (function walk(node) {
        if (node.nodeType === 3) { text.push(node.textContent); return; }
        if (node.nodeType === 1 && /^(STYLE|SCRIPT)$/.test(node.tagName)) { return; }
        if (node.nodeType === 1 && node.tagName === 'TR' && /group-row/.test(node.className) && node.offsetParent !== null) { rows += 1; }
        if (node.shadowRoot) { walk(node.shadowRoot); }
        Array.prototype.forEach.call(node.childNodes || [], walk);
      })(document.body);
      var all = text.join(' ').replace(/[\\s\\u00a0]+/g, ' ');
      var i = all.indexOf('Zarządzaj');
      return 'rows=' + rows + ' manage=' + i + ' near=' + (i >= 0 ? all.slice(Math.max(0, i - 40), i + 60).replace(/[0-9]/g, '#') : '') + ' account=' + (all.match(/#5\\d{7}/) || [''])[0].slice(-3);
    })()
    """

    private struct PensionPage: Decodable {
        let text: String
        let rows: [[String]]
    }

    private static func snapshot(of account: PensionAccount, _ result: Any?, now: Date) -> Snapshot? {
        guard let json = result as? String, let page = try? JSONDecoder().decode(PensionPage.self, from: Data(json.utf8)) else { return nil }
        return pensionSnapshot(label: account.label, text: page.text, rows: page.rows, now: now)
    }

    private func readPension(_ account: PensionAccount, now: Date) {
        webView?.evaluateJavaScript(Self.pensionScript) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.continuation != nil, self.pensionOpen?.account == account,
                      let snapshot = Self.snapshot(of: account, result, now: now) else { return }
                self.pensions[account] = snapshot
                self.pensionOnScreen = account
                Log.write("\(account.label) read: \(snapshot.positions.count) positions")
                self.pensionOpen = nil
                self.openNextPension()
            }
        }
    }

    /// Live mode: re-reads the pension account on screen; keeps the last values otherwise.
    private func refreshPension(now: Date) {
        guard let account = pensionOnScreen else { return }
        webView?.evaluateJavaScript(Self.pensionScript) { [weak self] result, _ in
            Task { @MainActor in
                if let snapshot = Self.snapshot(of: account, result, now: now) { self?.pensions[account] = snapshot }
            }
        }
    }

    /// Clicks the account in xStation's account switcher; the page then reloads on that account.
    /// If the switcher is missing, finishes with the accounts read so far.
    private func openAccount(_ accountNo: String) {
        let script = """
        (function () {
          var link = Array.prototype.find.call(document.querySelectorAll('.dropdown-menu a'), function (a) { return a.textContent.indexOf('\(accountNo)') >= 0; });
          if (!link) { return false; }
          link.click();
          return true;
        })()
        """
        webView?.evaluateJavaScript(script) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, self.continuation != nil else { return }
                Log.write("switch to account …\(accountNo.suffix(3)): \((result as? Bool) == true ? "clicked" : "not found")")
                if (result as? Bool) == true { self.pageAccount = accountNo }
                if (result as? Bool) != true {
                    self.collected.insert(accountNo)
                    self.finish(.snapshots(self.allSnapshots(now: Date())))
                }
            }
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.finish(.failed("okno logowania zostało zamknięte")) }
    }

    private func finish(_ outcome: RefreshOutcome) {
        guard let continuation else { return }
        self.continuation = nil
        if case .snapshots(let snapshots) = outcome {
            Log.write("refresh done: \(snapshots.count) accounts from \(received) messages; \(state.diagnostics)")
        } else {
            Log.write("refresh done: \(outcome) after \(received) messages")
        }
        timer?.invalidate()
        timer = nil
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.stopLoading()
        window?.delegate = nil
        window?.close()
        webView = nil
        window = nil
        continuation.resume(returning: outcome)
    }
}
