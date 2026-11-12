# XTB Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aplikacja macOS w pasku menu plus szeroki widget na pulpit, pokazujące na żywo podsumowanie kont XTB właściciela, z własną historią próbek co 15 minut i samodzielnym odnawianiem sesji.

**Architecture:** Pakiet Swift `XTBKit` zawiera całą logikę (protokół, sesja, portfel, magazyn próbek) i jest testowany przez `swift test` bez podpisywania. Aplikacja paska menu trzyma połączenie i zapisuje migawkę oraz próbki do kontenera App Group; rozszerzenie WidgetKit tylko czyta ten kontener. Pierwsze zadanie to spike na żywym koncie, który zamyka listę „Nieznane” ze specyfikacji i nagrywa dane testowe; kolejne zadania opierają się na jego ustaleniach.

**Tech Stack:** Swift 6, Swift Package Manager, XCTest, Foundation (`URLSession`, `URLSessionWebSocketTask`), Security (pęk kluczy), AppKit (`NSStatusItem`) z widokami SwiftUI, WidgetKit + AppIntents, XcodeGen (generuje projekt Xcode z `project.yml`, bo projektu nie da się wyklikać z wiersza poleceń).

**Spec:** `docs/superpowers/specs/2026-11-12-xtb-widget-design.md` (czytać razem z planem; makiety: `/Users/filipkostecki/repos/mine/.superpowers/brainstorm/65166-1794478573/content/widget.html`).

## Global Constraints

- macOS 27, Xcode 27.1. Starszych systemów nie wspieramy.
- Katalog projektu: `/Users/filipkostecki/repos/mine/xtb-widget`. Wszystkie ścieżki w planie są względem niego.
- Żadnego kodu wysyłającego zlecenia: w `XTBKit` nie istnieją komendy handlowe.
- Hasło, bilet główny i ciasteczka sesji wyłącznie w pęku kluczy (usługa `xtb-widget`). Nigdy w plikach, logach, wyjściu programu ani w kontenerze App Group.
- Najwyżej jedna próba logowania hasłem na uruchomienie spike'a; w aplikacji po odrzuceniu hasła zero dalszych prób bez akcji człowieka.
- Nieaktualne dane nie udają aktualnych: brak połączenia = szare liczby i znak ostrzeżenia.
- Próbka co 15 minut, tylko przy działającym połączeniu.
- Okresy wykresu: dzień, tydzień, miesiąc, wszystko; domyślnie dzień.
- Zadania 2 do 8 nie zaczynają się, dopóki `docs/findings.md` z zadania 1 nie ma odpowiedzi F1 do F10. Jeśli F9 (waluty) albo F10 (podpisywanie) wypadnie źle, stop i powrót do właściciela.
- Commity lokalne, bez wypychania.

## Review Focus

1. Połączenie umiera po cichu (uśpienie komputera, zmiana Wi-Fi, brak ramki zamknięcia): aplikacja ma to wykryć brakiem odpowiedzi na ping i połączyć się ponownie, zamiast pokazywać zamrożone liczby jako żywe. Test w zadaniu 5.
2. XTB zmienia kształt wiadomości albo przysyła nieznany element: nic się nie wywraca, wiadomość jest pomijana. Test w zadaniu 2.
3. Pozycja zostaje zamknięta albo kupiona w trakcie działania: wiersz znika albo pojawia się, sumy się zgadzają; konto bez pozycji nie powoduje dzielenia przez zero. Test w zadaniu 3.
4. Komputer wyłączony na kilka dni, poniedziałek, zmiana czasu: zmiana dzienna liczy się od ostatniej próbki sprzed północy, wykres ma przerwę, a nie linię przez dziurę. Test w zadaniu 4.
5. Plik próbek z uciętą ostatnią linią (awaria w trakcie zapisu): zła linia jest pomijana, reszta historii zostaje. Test w zadaniu 4.

---

## File Structure

```
Package.swift                         XTBKit (biblioteka), xtb-spike i xtb-watch (narzędzia), XTBKitTests
Sources/XTBKit/
  Protocol/Requests.swift             budowanie żądań JSON (tylko odczyt)
  Protocol/Events.swift               typy zdarzeń i dekodowanie wiadomości
  Portfolio/PortfolioState.swift      składanie zdarzeń w migawkę (suma kont, wiersze pozycji)
  Portfolio/Snapshot.swift            Snapshot, PositionRow (Codable, wspólne z widgetem)
  Store/SampleStore.swift             plik próbek, migawka, okresy wykresu
  Store/DailyChange.swift             zmiana dzienna, wyrównanie do kwadransów
  Session/SessionMachine.swift        czysta maszyna stanów sesji
  Session/CASClient.swift             logowanie CAS po HTTP
  Session/SocketClient.swift          gniazdo: wysyłka, odbiór, ping
  Session/Keychain.swift              odczyt i zapis sekretów
  Session/SessionController.swift     spina maszynę, CAS, gniazdo, pęk kluczy
  AppGroup.swift                      identyfikator grupy i katalog kontenera
Sources/xtb-spike/main.swift          spike (zadanie 1), zostaje jako narzędzie diagnostyczne
Sources/xtb-watch/main.swift          wypisuje migawki z prawdziwych komponentów (zadanie 6)
Tests/XTBKitTests/                    testy + Fixtures/*.json nagrane przez spike
App/                                  cel aplikacji: AppDelegate, StatusItemController, StatusItemView, SettingsView
Widget/                               cel rozszerzenia: PortfolioWidget, WidgetView, RangeIntent
Shared/Sparkline.swift                kształt wykresu, kompilowany do aplikacji i widgetu
project.yml                           definicja projektu dla XcodeGen
docs/findings.md                      ustalenia spike'a F1 do F10
```

---

### Task 1: Spike na żywym koncie

**Files:**
- Create: `Package.swift`, `Sources/xtb-spike/main.swift`, `docs/findings.md`, `Tests/XTBKitTests/Fixtures/*.json`, `.gitignore`

**Interfaces:**
- Produces: `docs/findings.md` z odpowiedziami F1 do F10 oraz pliki `Fixtures/login_result.json`, `total_balance.json`, `trade_profit.json`, `trade_record.json`, `symbols.json`, `unknown_event.json` (po jednej prawdziwej wiadomości, z podmienionymi danymi osobowymi, numerami kont i biletami).

- [ ] **Step 1: Założenie repozytorium i pakietu**

`git init`; `.gitignore` z `.build/`, `*.xcodeproj`, `DerivedData/`, `.superpowers/`. `Package.swift`: platforma `.macOS(.v15)` lub wyższa dostępna w toolchainie, cel wykonywalny `xtb-spike`.

- [ ] **Step 2: Prośba do właściciela o hasło w pęku kluczy**

Właściciel sam uruchamia w swoim terminalu (polecenie zapyta o hasło, nie pokazując go):

```bash
security add-generic-password -s xtb-widget -a "<login XTB>" -w
```

Agent nie wpisuje ani nie odczytuje hasła samodzielnie; czyta je wyłącznie kod spike'a.

- [ ] **Step 3: Napisanie `xtb-spike`**

Jeden plik, bez abstrakcji. Argument: login. Przebieg: hasło z pęku kluczy (`SecItemCopyMatching`), `POST /signon/v2/tickets` z `rememberMe: true` i stałym `fingerprint` (64 znaki hex, losowany raz i zapisany w pęku kluczy pod kontem `fingerprint`), `POST /signon/v2/serviceTicket` dla `xapi5`, gniazdo `wss://api5reala.x-station.eu/v1/xstation`, `registerClientInfo`, `logonWithServiceTicket`, dla każdego niearchiwalnego konta `getAndSubscribeElement` dla `eid` 1043, 1038 i 1 oraz `getElement` dla `eid` 3. Adresy, pola i kolejność: sekcja „Ustalone z rekonesansu” w specyfikacji. Wypisuje typy wiadomości i ich kształty; wartości pól `ticket`, `serviceTicket`, `password`, ciasteczek i `userData` zastępuje długością. Przełącznik `--record <katalog>` zapisuje po jednej wiadomości każdego rodzaju do plików. Przełącznik `--hold <minuty>` trzyma połączenie i loguje każde zamknięcie z kodem. Przy odpowiedzi innej niż sukces na logowanie hasłem program kończy pracę bez ponawiania.

- [ ] **Step 4: Uruchomienie i spisanie ustaleń**

Run: `swift run xtb-spike "<login>" --record Tests/XTBKitTests/Fixtures --hold 30`, z otwartym obok xStation właściciela.

W `docs/findings.md` zapisać:

- **F1** Jak bilet główny trafia do żądania `serviceTicket` (ciasteczko o jakiej nazwie, nagłówek).
- **F2** Dokładna wartość `loginPhase` przy sukcesie.
- **F3** Ping: kto go wysyła, w jakiej postaci i co ile sekund; po ilu sekundach ciszy serwer zamyka połączenie. Jeśli z 30 minut nie da się tego ustalić, przyjąć ping WebSocket co 30 s.
- **F4** Kształt wpisu listy pozycji (`eid 1`): pole identyfikatora pozycji, symbolu, wolumenu, znacznik zamknięcia.
- **F5** Kształt słownika instrumentów: pole klucza i pole nazwy wyświetlanej; lista `fields` użyta w żądaniu.
- **F6** Jak wygląda usunięcie wiersza (wartość `row.state` przy zamknięciu pozycji), jeśli dało się zaobserwować; inaczej zapisać „nie zaobserwowano” i przyjąć, że pozycja z zerowym wolumenem albo brakiem w kolejnym pełnym odczycie znika.
- **F7** Które pole `xtotalbalance` równa się „wartości konta”, a które pole zysku (`profit` czy `netProfit`) równa się zyskowi pokazywanemu w xStation. Porównanie z ekranem właściciela.
- **F8** Czy równoległe logowanie w xStation (web) zamyka połączenie spike'a i z jakim kodem. Właściciel loguje się w przeglądarce w trakcie `--hold`.
- **F9** Waluty kont z `accountList`. Różne waluty: stop, powrót do właściciela.
- **F10** Podpisywanie: po zalogowaniu właściciela do Xcode (Settings, Accounts) sprawdzić `security find-identity -v -p codesigning` i ustalić, czy darmowe konto pozwala zbudować aplikację z rozszerzeniem widgetu i wspólnym kontenerem App Group oraz jaki identyfikator grupy działa. Zapisać identyfikator zespołu i grupy. Jeśli się nie da: stop, powrót do właściciela.

- [ ] **Step 5: Przegląd plików Fixtures**

Run: `grep -rIl -E "<login>|<numer konta>" Tests/XTBKitTests/Fixtures; echo $?`
Expected: brak plików, kod `1`. Ręcznie potwierdzić, że nie ma imienia, adresu, biletów.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "spike: XTB login and data stream findings"
```

---

### Task 2: Żądania i dekodowanie zdarzeń

**Files:**
- Create: `Sources/XTBKit/Protocol/Requests.swift`, `Sources/XTBKit/Protocol/Events.swift`
- Test: `Tests/XTBKitTests/RequestsTests.swift`, `Tests/XTBKitTests/EventsTests.swift`
- Modify: `Package.swift` (cel `XTBKit`, cel testowy z `resources: [.copy("Fixtures")]`)

**Interfaces:**
- Consumes: Fixtures i F2, F4, F5, F6, F7 z zadania 1.
- Produces:

```swift
public struct XTBAccount: Equatable, Sendable { public let accountId: String; public let accountNo: String; public let currency: String; public let isArchived: Bool }
public struct TotalBalance: Equatable, Sendable { public let accountNo: String; public let equity: Double; public let profit: Double }   // pola wybrane wg F7
public struct TradeProfit: Equatable, Sendable { public let idPosition: Int; public let profit: Double; public let marketValue: Double }
public struct Trade: Equatable, Sendable { public let idPosition: Int; public let symbolKey: String; public let isOpen: Bool }
public struct Instrument: Equatable, Sendable { public let key: String; public let name: String }
public enum XTBEvent: Equatable, Sendable {
    case loginResult([XTBAccount])
    case balance(TotalBalance)
    case tradeProfit(TradeProfit)
    case trade(Trade)
    case instruments([Instrument])
    case requestFailed(reqId: String, status: Int)
}
public func decodeEvents(_ message: Data) -> [XTBEvent]      // nieznane kształty pomija, nigdy nie rzuca

public enum XTBRequest {
    public static func registerClientInfo(reqId: String) -> Data
    public static func logon(serviceTicket: String, reqId: String) -> Data
    public static func getAndSubscribe(eid: Int, accountId: String, reqId: String) -> Data
    public static func getInstruments(accountId: String, reqId: String) -> Data
}
public enum ElementID { public static let trades = 1, instruments = 3, tradeProfit = 1038, totalBalance = 1043 }
```

- [ ] **Step 1: Testy dekodowania (failing)**

Po jednym teście na plik Fixtures: `login_result.json` daje `.loginResult` z liczbą kont równą liczbie w pliku i poprawną walutą; `total_balance.json` daje `.balance` z wartościami z pliku; analogicznie `trade_profit.json`, `trade_record.json`, `symbols.json`. Do tego:

```swift
func testUnknownElementIsSkipped() { XCTAssertEqual(decodeEvents(fixture("unknown_event")), []) }
func testGarbageIsSkipped() { XCTAssertEqual(decodeEvents(Data("not json".utf8)), []) }
func testKnownShapeWithMissingFieldIsSkipped() // total_balance bez pola equity -> []
func testMixedBatchKeepsValidEvents()           // tablica: poprawne saldo + nieznany element -> 1 zdarzenie
func testNonZeroStatusBecomesRequestFailed()
```

- [ ] **Step 2: Testy żądań (failing)**

Każde żądanie po zdekodowaniu z powrotem do JSON ma `reqId` i `command[0].CoreAPI` z właściwą operacją; `getAndSubscribe(eid: 1043, accountId: "meta1_1", …)` ma `getAndSubscribeElement.eid == 1043`, `endpoint == "meta1"`, `accountId == "meta1_1"`; `registerClientInfo` ma `apiVersion == "2.73.0"`. Test strażnik: plik `Requests.swift` nie zawiera słów `trade`/`order` w nazwach operacji (asercja na liście publicznych funkcji przez stałą `XTBRequest.allOperationNames`).

- [ ] **Step 3: Run** `swift test --filter "RequestsTests|EventsTests"` → FAIL (brak symboli).
- [ ] **Step 4: Implementacja** obu plików. Dekodowanie przez `JSONSerialization` i ręczne wyciąganie pól (kształty są luźne, a brak pola ma oznaczać pominięcie, nie błąd).
- [ ] **Step 5: Run** ten sam filtr → PASS.
- [ ] **Step 6: Commit** `feat: XTB request building and event decoding`.

---

### Task 3: Stan portfela i migawka

**Files:**
- Create: `Sources/XTBKit/Portfolio/Snapshot.swift`, `Sources/XTBKit/Portfolio/PortfolioState.swift`
- Test: `Tests/XTBKitTests/PortfolioStateTests.swift`

**Interfaces:**
- Consumes: `XTBEvent` i typy z zadania 2.
- Produces:

```swift
public struct PositionRow: Codable, Equatable, Sendable { public let name: String; public let value: Double; public let profit: Double; public let profitPercent: Double }
public struct Snapshot: Codable, Equatable, Sendable {
    public let equity: Double; public let profit: Double; public let profitPercent: Double
    public let currency: String; public let positions: [PositionRow]
    public let updatedAt: Date; public var connected: Bool
}
public struct PortfolioState: Sendable {
    public init()
    public mutating func apply(_ event: XTBEvent)
    public var accounts: [XTBAccount] { get }            // niearchiwalne
    public var isComplete: Bool { get }                   // jest saldo każdego konta
    public func snapshot(now: Date) -> Snapshot?          // nil, dopóki !isComplete
}
```

Reguły: `equity` i `profit` to sumy po kontach. Wiersz powstaje z otwartych pozycji o tym samym `symbolKey` ze wszystkich kont; `value` = suma `marketValue`, `profit` = suma `profit`; nazwa z instrumentów, a przy braku wpisu sam `symbolKey`. Procent wiersza i procent łączny: `profit / (value − profit) × 100`, a gdy mianownik ≤ 0, to `0`. Kolejność: malejąco po `value`.

- [ ] **Step 1: Testy (failing)**

```swift
func testSumsBalancesAcrossAccounts()            // 2 konta: equity 1000+500, profit 100+(-20) -> 1500, 80
func testSnapshotNilUntilEveryAccountHasBalance()
func testGroupsSameSymbolAcrossAccounts()        // AAPL na 2 kontach -> 1 wiersz, sumy
func testSortsByValueDescending()
func testClosedPositionDisappears()              // .trade(isOpen:false) po otwartej -> brak wiersza
func testNewPositionAppears()
func testProfitUpdateReplacesPrevious()          // drugi tradeProfit tej samej pozycji nadpisuje, nie dodaje
func testNoPositionsGivesEmptyListAndZeroPercent()
func testMissingInstrumentFallsBackToSymbolKey()
func testPercentFormula()                        // value 1100, profit 100 -> 10.0
func testArchivedAccountIgnored()
```

- [ ] **Step 2: Run** `swift test --filter PortfolioStateTests` → FAIL.
- [ ] **Step 3: Implementacja.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: portfolio aggregation across accounts`.

---

### Task 4: Magazyn próbek, okresy, zmiana dzienna

**Files:**
- Create: `Sources/XTBKit/Store/SampleStore.swift`, `Sources/XTBKit/Store/DailyChange.swift`, `Sources/XTBKit/AppGroup.swift`
- Test: `Tests/XTBKitTests/SampleStoreTests.swift`, `Tests/XTBKitTests/DailyChangeTests.swift`

**Interfaces:**
- Consumes: `Snapshot` z zadania 3; identyfikator grupy z F10.
- Produces:

```swift
public struct Sample: Codable, Equatable, Sendable { public let t: Date; public let equity: Double; public let profit: Double }
public enum ChartRange: String, CaseIterable, Codable, Sendable { case day, week, month, all }   // 24 h, 7 dni, 30 dni, wszystko
public struct SampleStore: Sendable {
    public init(directory: URL)
    public func append(_ sample: Sample) throws
    public func samples(in range: ChartRange, now: Date) -> [Sample]
    public func writeSnapshot(_ snapshot: Snapshot) throws      // zapis atomowy
    public func readSnapshot() -> Snapshot?
}
public func dailyChange(currentProfit: Double, samples: [Sample], now: Date, calendar: Calendar) -> Double?
public func nextSampleDate(after date: Date, calendar: Calendar) -> Date       // najbliższy pełny kwadrans
public func segments(_ samples: [Sample], maxGap: TimeInterval) -> [[Sample]]  // dzieli wykres na odcinki w miejscach przerw
public enum AppGroup { public static let id: String; public static func containerURL() -> URL? }
```

Pliki: `samples.jsonl` (jedna próbka JSON na linię, dopisywanie) i `snapshot.json`. Daty jako sekundy od 1970. Przerwa na wykresie: odstęp większy niż 45 minut.

- [ ] **Step 1: Testy (failing)**

```swift
// SampleStoreTests (katalog tymczasowy)
func testAppendThenReadAll()
func testRangeDayReturnsOnlyLast24h()
func testRangeWeekAndMonthBoundaries()
func testTruncatedLastLineIsSkipped()          // dopisać "{\"t\":17" na końcu pliku -> pozostałe próbki wracają
func testAppendAfterTruncatedLineStillReadable()
func testMissingFileGivesEmpty()
func testSnapshotRoundTrip()
func testReadSnapshotNilWhenCorrupt()

// DailyChangeTests (kalendarz Europe/Warsaw)
func testUsesLastSampleBeforeTodayMidnight()   // próbki wczoraj 21:45 profit 100, dziś 09:00 profit 130; teraz 150 -> 50
func testMondayUsesFridaySample()
func testNilWhenNoEarlierSample()              // tylko dzisiejsze próbki -> nil
func testAcrossDSTChange()                     // 2026-10-25, północ lokalna liczona kalendarzem
func testNextSampleDateRoundsUpToQuarter()     // 10:07:30 -> 10:15:00; 10:15:00 -> 10:30:00
func testSegmentsSplitOnGap()                  // odstęp 3 h -> 2 odcinki; odstępy 15 min -> 1
```

- [ ] **Step 2: Run** `swift test --filter "SampleStoreTests|DailyChangeTests"` → FAIL.
- [ ] **Step 3: Implementacja.**
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: sample store, chart ranges, daily change`.

---

### Task 5: Maszyna stanów sesji

**Files:**
- Create: `Sources/XTBKit/Session/SessionMachine.swift`
- Test: `Tests/XTBKitTests/SessionMachineTests.swift`

**Interfaces:**
- Consumes: F2, F3, F8.
- Produces:

```swift
public enum SessionState: Equatable, Sendable { case idle, connecting, connected, waiting, needsHuman(HumanReason) }
public enum HumanReason: Equatable, Sendable { case noCredentials, passwordRejected, secondFactorRequired }
public enum SessionEvent: Equatable, Sendable {
    case start(hasTicket: Bool, hasPassword: Bool)
    case serviceTicketIssued, serviceTicketRejected, loginSucceeded
    case loginRejected(HumanReason)                 // złe hasło albo loginPhase inny niż sukces
    case transportFailed                            // błąd sieci na dowolnym kroku
    case socketReady, socketClosed(displaced: Bool), pingTimedOut
    case retryTimerFired, systemWoke, networkChanged
    case userRequestedLogin(hasPassword: Bool)
}
public enum SessionAction: Equatable, Sendable { case requestServiceTicket, loginWithPassword, openSocket, closeSocket, scheduleRetry(seconds: Int), cancelRetry }
public struct SessionMachine: Sendable {
    public init()
    public private(set) var state: SessionState
    public mutating func handle(_ event: SessionEvent) -> [SessionAction]
}
```

Reguły: kolejne odstępy ponowień 2, 4, 8, … do 300 s, zerowane po `socketReady`. Po `socketClosed(displaced: true)` odstęp 900 s. `pingTimedOut` działa jak zerwane gniazdo: `closeSocket` i ponowienie. `systemWoke` i `networkChanged` w stanie `waiting` albo `connected` dają natychmiastową próbę od biletu usługi. Hasło idzie w ruch tylko po `serviceTicketRejected` albo przy starcie bez biletu.

- [ ] **Step 1: Testy (failing)**

```swift
func testStartWithTicketRequestsServiceTicketFirst()
func testStartWithoutTicketLogsInWithPassword()
func testStartWithoutPasswordNeedsHuman()
func testServiceTicketRejectedFallsBackToPasswordOnce()
func testPasswordRejectedStopsEverything()       // potem retryTimerFired, systemWoke, networkChanged, socketClosed -> [] i stan needsHuman
func testSecondFactorStopsEverything()
func testUserRequestedLoginLeavesNeedsHuman()
func testSocketDropReconnectsWithServiceTicketNotPassword()
func testBackoffSequenceAndCap()                 // 2,4,8,16,32,64,128,256,300,300
func testBackoffResetsAfterSocketReady()
func testDisplacedWaits900Seconds()
func testPingTimeoutClosesAndRetries()
func testWakeTriggersImmediateReconnect()
func testTransportFailureDuringPasswordLoginRetriesWithoutNeedsHuman()
func testNoPasswordLoginIssuedTwiceWithoutTicketRejectionBetween()   // losowe sekwencje zdarzeń, 1000 przebiegów, stałe ziarno
```

- [ ] **Step 2: Run** `swift test --filter SessionMachineTests` → FAIL.
- [ ] **Step 3: Implementacja** jako czysta funkcja przejścia, bez zegarów i sieci.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat: session state machine`.

---

### Task 6: Sieć, pęk kluczy i kontroler sesji

**Files:**
- Create: `Sources/XTBKit/Session/Keychain.swift`, `CASClient.swift`, `SocketClient.swift`, `SessionController.swift`, `Sources/xtb-watch/main.swift`
- Test: `Tests/XTBKitTests/CASClientTests.swift`
- Modify: `Package.swift` (cel `xtb-watch`)

**Interfaces:**
- Consumes: `SessionMachine` (zad. 5), `XTBRequest`, `decodeEvents` (zad. 2), `PortfolioState` (zad. 3); F1, F2, F3, F8.
- Produces:

```swift
public enum Keychain {   // usługa "xtb-widget"
    public static func read(account: String) -> String?
    public static func write(_ value: String, account: String) throws
    public static func delete(account: String)
}
public enum CASError: Error, Equatable { case rejected(HumanReason), transport }
public struct CASClient: Sendable {
    public init(session: URLSession, fingerprint: String)
    public func login(username: String, password: String) async throws(CASError) -> String      // zwraca bilet główny w postaci do przechowania wg F1
    public func serviceTicket(ticket: String) async throws(CASError) -> String?                 // nil = bilet główny odrzucony
}
public final class SocketClient: Sendable {
    public init(url: URL)
    public func connect() async throws
    public func send(_ data: Data) async throws
    public var messages: AsyncStream<Data> { get }
    public var closures: AsyncStream<(code: Int, displaced: Bool)> { get }   // displaced wg F8
    public func close()
}
@MainActor public final class SessionController {
    public init(username: @escaping () -> String?)
    public var onSnapshot: ((Snapshot) -> Void)?           // przy każdej zmianie, connected == true
    public var onStateChange: ((SessionState) -> Void)?
    public func start()
    public func userRequestedLogin()
    public func systemWoke(); public func networkChanged()
}
```

Konta w pęku kluczy: hasło pod loginem, bilet główny pod `ticket`, odcisk pod `fingerprint`. Kontroler wykonuje akcje maszyny, po `socketReady` wysyła `registerClientInfo`, `logon`, a po `loginResult` subskrypcje dla każdego niearchiwalnego konta; pinguje wg F3 i zgłasza `pingTimedOut` po dwóch pominiętych odpowiedziach. Niczego z sekretów nie loguje.

- [ ] **Step 1: Testy CASClient (failing)** ze stubem `URLProtocol`:

```swift
func testLoginSendsExpectedBodyAndHeaders()      // username, password, fingerprint, rememberMe == true; nagłówki Content-Type, Time-Zone, Accept
func testLoginSuccessReturnsTicket()             // 201, loginPhase == wartość z F2
func testLoginWrongPasswordIsRejected()          // success false / 401 -> .rejected(.passwordRejected)
func testLoginOtherPhaseIsSecondFactor()         // success true, loginPhase inny niż F2 -> .rejected(.secondFactorRequired)
func testLoginNetworkErrorIsTransport()
func testServiceTicketSendsTicketPerFindings()   // sposób przekazania wg F1, body {"service":"xapi5"}
func testServiceTicketRejectedReturnsNil()       // 401/403 albo success false
func testServiceTicket5xxIsTransport()
```

- [ ] **Step 2: Run** `swift test --filter CASClientTests` → FAIL.
- [ ] **Step 3: Implementacja** `Keychain`, `CASClient`, `SocketClient` (`URLSessionWebSocketTask`), `SessionController`.
- [ ] **Step 4: Run** `swift test` → wszystko PASS.
- [ ] **Step 5: `xtb-watch`**: uruchamia `SessionController`, wypisuje każdą zmianę stanu i migawkę (suma, zysk, liczba pozycji, pierwsze 3 wiersze).
- [ ] **Step 6: Weryfikacja na żywo**

Run: `swift run xtb-watch "<login>"`
Expected: stan `connected` w kilka sekund; suma i zysk zgodne z xStation właściciela; po wyłączeniu i włączeniu Wi-Fi powrót do `connected` bez logowania hasłem (w wyjściu widać `requestServiceTicket`, nie `loginWithPassword`); drugie uruchomienie startuje z biletu, bez hasła.

- [ ] **Step 7: Commit** `feat: CAS client, socket, keychain, session controller`.

---

### Task 7: Aplikacja w pasku menu

**Files:**
- Create: `project.yml`, `App/AppDelegate.swift`, `App/StatusItemController.swift`, `App/StatusItemView.swift`, `App/SettingsView.swift`, `App/Info.plist`, `App/XTBBar.entitlements`, `Shared/Sparkline.swift`

**Interfaces:**
- Consumes: `SessionController` (zad. 6), `SampleStore`, `dailyChange`, `nextSampleDate`, `segments`, `ChartRange`, `AppGroup` (zad. 4), `Snapshot` (zad. 3); identyfikator zespołu i grupy z F10.
- Produces: cel `XTBBar` (bundle id `pl.local.xtbbar`); `struct Sparkline: Shape { init(segments: [[Double]]) }` w `Shared/`; klucz `UserDefaults` `menuBarRange` (wartość `ChartRange.rawValue`); pliki `snapshot.json` i `samples.jsonl` w kontenerze grupy; po każdym zapisie `WidgetCenter.shared.reloadAllTimelines()`.

- [ ] **Step 1: Projekt.** `brew install xcodegen`; `project.yml` z celem aplikacji `XTBBar` (`LSUIElement: true`, zależność od lokalnego pakietu `XTBKit`, entitlement App Group z F10, podpis zespołem z F10). `xcodegen generate`.
- [ ] **Step 2: `Sparkline`.** Kształt rysujący każdy odcinek jako osobną łamaną, skalowany do wspólnego min/max; przy jednej próbce pozioma kreska; przy braku danych pusta ścieżka.
- [ ] **Step 3: `StatusItemView` (SwiftUI).** Wejście: `Snapshot?`, `dailyChange: Double?`, punkty wykresu, `hovered`. Układ jak w makiecie „Pasek menu”: wykres 30×16, dwie linijki 10 pt (łączny zysk; `dziś ±X zł`, a przy `nil` linijka pusta). Przy `hovered` między wykresem a linijkami wartość konta 13 pt. Kolory: zielony dla ≥ 0, czerwony dla < 0. Przy `snapshot == nil` albo `connected == false`: liczby szare i symbol `exclamationmark.triangle`. Kwoty bez groszy, ze spacją jako separatorem tysięcy i walutą z migawki (PLN jako `zł`).
- [ ] **Step 4: `StatusItemController`.** `NSStatusItem` o zmiennej długości z `NSHostingView`; `onHover` przełącza `hovered` i ustawia długość elementu na szerokość widoku. Menu: wiersz stanu z czasem ostatniej aktualizacji, „Zaloguj ponownie”, podmenu „Okres wykresu” (4 pozycje, zaznaczona bieżąca), „Ustawienia…”, „Zakończ”.
- [ ] **Step 5: `AppDelegate`.** Tworzy `SessionController`; `onSnapshot` odświeża widok na żywo; zegar ustawiany na `nextSampleDate` zapisuje próbkę i migawkę tylko w stanie `connected`; przy każdej zmianie stanu na inny niż `connected` zapisuje ostatnią migawkę z `connected = false`; obserwuje `NSWorkspace.didWakeNotification` i `NWPathMonitor`; rejestruje start przy logowaniu przez `SMAppService.mainApp`.
- [ ] **Step 6: `SettingsView`.** Pola login i hasło (`SecureField`), przycisk „Zapisz i zaloguj”: login do `UserDefaults`, hasło do pęku kluczy, potem `userRequestedLogin()`. Hasła nie wyświetla po zapisaniu.
- [ ] **Step 7: Budowa i uruchomienie**

Run: `xcodebuild -project XTBBar.xcodeproj -scheme XTBBar -configuration Debug build` → `BUILD SUCCEEDED`, potem uruchomić zbudowaną aplikację.
Expected (sprawdza właściciel przy otwartym xStation): w pasku wykres i dwie linijki; najechanie pokazuje wartość konta i sąsiednie ikony się przesuwają; zjechanie przywraca wersję wąską; liczby zmieniają się na żywo i zgadzają z xStation; po wyłączeniu Wi-Fi w kilkadziesiąt sekund liczby szarzeją ze znakiem ostrzeżenia, po włączeniu wracają; zmiana okresu w menu zmienia wykres; po kwadransie w kontenerze grupy przybywa linia w `samples.jsonl`.

- [ ] **Step 8: Commit** `feat: menu bar app`.

---

### Task 8: Widget na pulpit

**Files:**
- Create: `Widget/PortfolioWidget.swift`, `Widget/WidgetView.swift`, `Widget/RangeIntent.swift`, `Widget/Info.plist`, `Widget/XTBWidget.entitlements`
- Modify: `project.yml` (cel rozszerzenia `XTBWidget`, osadzony w `XTBBar`, ten sam App Group)

**Interfaces:**
- Consumes: `SampleStore`, `ChartRange`, `dailyChange`, `segments`, `AppGroup`, `Snapshot`, `Sparkline`.
- Produces: widget `kind` `"XTBPortfolio"`, rodzina `.systemExtraLarge`, konfiguracja `RangeIntent` z parametrem `range` (domyślnie dzień).

- [ ] **Step 1: `RangeIntent`.** `WidgetConfigurationIntent` z jednym parametrem typu wyliczeniowego o 4 wartościach i polskich nazwach: Dzień, Tydzień, Miesiąc, Wszystko.
- [ ] **Step 2: Dostawca osi czasu.** Czyta migawkę i próbki z kontenera; jeden wpis „teraz”, polityka `.after(nextSampleDate)`. Wpis niesie: `Snapshot?`, zmianę dzienną, odcinki wykresu, `isStale` = brak migawki, `connected == false` albo `updatedAt` starsze niż 20 minut.
- [ ] **Step 3: `WidgetView`.** Układ „C. Szeroki” z makiety: lewa kolumna wartość konta 24 pt, zysk z procentem, `dziś ±X zł`, wykres z wypełnieniem; prawa kolumna tabela pozycji (nazwa, wartość, procent), tyle wierszy, ile się mieści, a nadmiar jako „+ N kolejnych”. Przy `isStale` liczby szare i dopisek „dane z HH:mm”. Bez migawki: napis „Otwórz XTBBar i zaloguj się”.
- [ ] **Step 4: Budowa i sprawdzenie**

Run: `xcodegen generate && xcodebuild -project XTBBar.xcodeproj -scheme XTBBar build` → `BUILD SUCCEEDED`; uruchomić aplikację, dodać widget na pulpit.
Expected (sprawdza właściciel): widget w największym rozmiarze pokazuje te same sumy co pasek, wszystkie pozycje posortowane od największej; „Edytuj widget” pozwala zmienić okres i wykres się zmienia; po zakończeniu aplikacji i odczekaniu ponad 20 minut widget szarzeje z dopiskiem czasu.

- [ ] **Step 5: Commit** `feat: desktop widget`.

---

## Self-Review (wykonany)

- **Pokrycie specyfikacji:** pasek i najechanie (zad. 7), widget (zad. 8), próbki co 15 min i zmiana dzienna (zad. 4, 7), okresy (zad. 4, 7, 8), sesja i ustępowanie (zad. 5, 6), suma kont (zad. 3, 6), sekrety w pęku kluczy (zad. 1, 6, 7), brak komend handlowych (zad. 2), stan nieaktualny (zad. 7, 8), nieznane ze specyfikacji (zad. 1).
- **Bez testów automatycznych:** `SocketClient`, `SessionController`, warstwa interfejsu. Sprawdzane na żywo w krokach 6.6, 7.7, 8.4.
- **Zależność od ustaleń:** kształty `Trade`, `Instrument`, przekazanie biletu i ping są w planie nazwane semantycznie; dokładne nazwy pól pochodzą z `docs/findings.md`.
