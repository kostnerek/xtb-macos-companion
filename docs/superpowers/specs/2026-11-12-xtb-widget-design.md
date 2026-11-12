# XTB w pasku menu i na pulpicie: projekt

Data: 2026-11-12. Status: zaakceptowany przez właściciela 2026-11-12.

## Po co

Właściciel konta XTB chce widzieć stan swoich inwestycji bez otwierania xStation: jednym spojrzeniem w pasek menu macOS i na widget na pulpicie. XTB nie ma publicznego API, więc aplikacja rozmawia z tymi samymi serwerami co webowy xStation 5. Dwa wymagania są równie ważne jak same liczby: sesja ma wygasać jak najrzadziej, a po wygaśnięciu aplikacja ma zalogować się ponownie sama.

## Cele

1. **Pasek menu, na żywo.** Mały wykres zysku, obok dwie linijki: łączny zysk na otwartych pozycjach, pod nim zmiana z dzisiejszego dnia. Po najechaniu myszą ten sam element rozszerza się w miejscu i dodatkowo pokazuje wartość konta; po zjechaniu wraca do wersji wąskiej. Bez dymka ani popovera przy najechaniu (wyraźna decyzja właściciela; przesuwanie sąsiednich ikon jest akceptowane).
2. **Widget na pulpit, największy rozmiar (szeroki).** Po lewej wartość konta, łączny zysk z procentem, zmiana dzienna i wykres zysku. Po prawej lista wszystkich otwartych pozycji: nazwa, wartość, zysk w procentach.
3. **Historia.** Aplikacja sama zapisuje próbkę co 15 minut. Wykres zaczyna się od dnia instalacji.
4. **Okres wykresu konfigurowalny** (decyzja właściciela), osobno dla paska i dla widgetu.
5. **Sesja.** Jak najrzadsze wylogowania, automatyczne ponowne logowanie hasłem z pęku kluczy.

## Poza zakresem

- Składanie, zmiana i zamykanie zleceń. Aplikacja tylko czyta.
- Konto demo, przełączanie między kontami, osobny widok dla każdego konta.
- Historia sprzed instalacji, import z xStation.
- Powiadomienia, alerty cenowe, wersja na iOS.
- Obsługa logowania z kodem 2FA. Dopóki XTB go nie wymusza, nie budujemy okna na kod; jeśli wymusi, aplikacja stanie w stanie „wymaga człowieka” i będzie to osobne zadanie.
- Dystrybucja innym osobom (App Store, notaryzacja). To narzędzie na jeden komputer.

## Czego nie wolno zepsuć

- **Żadnego kodu wysyłającego zlecenia.** W kliencie protokołu nie istnieją komendy handlowe, nawet nieużywane.
- **Nieaktualne dane nie udają aktualnych.** Gdy nie ma połączenia, liczby szarzeją i pojawia się znak ostrzeżenia.
- **Hasło i bilety sesji tylko w pęku kluczy.** Nigdy w plikach, logach ani w kontenerze współdzielonym z widgetem.
- **Bez pętli logowania.** Nieudane logowanie hasłem nie jest ponawiane w kółko (ryzyko blokady konta): po błędnym haśle albo żądaniu 2FA aplikacja staje i czeka na człowieka.

## Ustalone z rekonesansu (ruch webowego xStation 5, wersja 2.111.0, podejrzany 2026-11-12)

### Logowanie (CAS)

- `POST https://xstation.xtb.com/signon/v2/tickets`, JSON: `username`, `password`, `fingerprint` (64 znaki), `rememberMe` (bool). Nagłówki żądania: `Content-Type`, `Time-Zone`, `Accept`. Odpowiedź 201: `success`, `loginPhase` (11 znaków przy udanym logowaniu bez 2FA), `ticket` (94 znaki, bilet główny).
- `POST https://xstation.xtb.com/signon/v2/serviceTicket`, JSON: `{"service": "xapi5"}`. Odpowiedź 201: `success`, `serviceTicket` (55 znaków). W treści żądania nie ma biletu głównego, więc trafia tam inną drogą, najpewniej ciasteczkiem ustawionym przez pierwszy krok. Do potwierdzenia w spike'u.
- xStation prosi też o bilet dla usługi `abigail` i woła gRPC-web na `ipax.xtb.com` (`AuthService/CreateAccessToken` i inne). Do danych portfela nie jest to potrzebne.
- Strona ładuje moduł 2FA i pyta `MfaGrpcFlagService/GetMfaAvailability`. Konto właściciela loguje się dziś samym hasłem.

### Gniazdo danych

- `wss://api5reala.x-station.eu/v1/xstation`, wiadomości to JSON.
- Żądanie: `{"reqId": "<nazwa>_<timestamp>_<licznik>", "command": [{"CoreAPI": {"endpoint": ..., "accountId": ..., <operacja>: {...}}}]}`.
- Kolejność po połączeniu:
  1. `registerClientInfo` z `clientInfo` (`appName`, `appVersion`, `device`, `apiVersion: "2.73.0"`, `osType`, `deviceType`, `comment`), `endpoint` pusty.
  2. `logonWithServiceTicket` z `serviceTicket`. Odpowiedź `xloginresult` zawiera `accountList` (`wtAccountId`, `currency`, `endpointType`, `isArchived`...), `endpointList`, `userData`.
  3. Subskrypcje `getAndSubscribeElement` z `eid`, `endpoint: "meta1"`, `accountId: "meta1_<numer konta>"`.
- Numery elementów (`eid`):
  - `1043` saldo: `xtotalbalance` z polami `balance`, `equity`, `totalEquity`, `profit`, `netProfit`, `stockValue`, `cashStockValue`, `freeMargin` i innymi.
  - `1038` zysk pozycji: `xtradeprofit` z polami `idPosition`, `profit`, `netProfit`, `netProfitPercent`, `marketValue`.
  - `1` lista pozycji (trade record). Kształt nieodczytany.
  - `3` słownik instrumentów (`getElement` z listą `fields`), `4` grupy instrumentów.
- Zdarzenia przychodzą jako `{"status": 0, "events": [{"scope": "ACCOUNT", "element": 1043, "row": {"state", "value": {...}, "stamp"}, "ctx": {...}}]}`.

### Nieznane (do ustalenia w spike'u, punkt pierwszy planu)

- Czas życia biletu głównego i wpływ `rememberMe`.
- Podtrzymanie połączenia: ping i jego odstęp (dzieje się w workerze strony, nie był widoczny).
- Kształt listy pozycji (`eid 1`) i sposób połączenia jej z nazwą instrumentu.
- Czy sesja aplikacji może działać równolegle z xStation właściciela (web, telefon), czy jedna wyrzuca drugą.
- Czy darmowe konto Apple wystarcza do trwałego podpisu aplikacji z widgetem i App Group na macOS 27, czy podpis wygasa po kilku dniach.
- Jak powstaje `fingerprint` (wygląda na skrót SHA-256 w hex; założenie: wygenerować raz i trzymać stały).
- Wartości `loginPhase` inne niż sukces (2FA).
- Które pole odpowiada „wartości konta” i „zyskowi” widocznym w xStation. Porównać z ekranem xStation.

## Jak to ma działać

### Części

- **Aplikacja w pasku menu** (Swift, bez ikony w Docku, uruchamiana przy logowaniu). Trzyma połączenie, zapisuje próbki, rysuje element paska. Element paska to własny widok `NSStatusItem` z obszarem śledzenia myszy, bo rozszerzanie w miejscu po najechaniu wymaga pełnej kontroli nad widokiem.
- **Rozszerzenie widgetu** (WidgetKit, rodzina największa szeroka). Nie łączy się z siecią. Czyta ostatnią migawkę i próbki ze wspólnego kontenera App Group.
- **Klient XTB**: logowanie CAS, gniazdo, parsowanie zdarzeń. Tylko odczyt.
- **Magazyn próbek**: plik we wspólnym kontenerze. Próbka co 15 minut: czas, wartość konta, łączny zysk. Do tego migawka bieżącego stanu (saldo i pozycje) nadpisywana przy każdej próbce.

### Sesja

Stany: połączony, łączenie, wymaga człowieka.

1. Start: jeśli jest zapisany bilet główny, poproś o bilet usługi i połącz gniazdo. Jeśli nie ma albo został odrzucony, zaloguj hasłem z pęku kluczy (`rememberMe: true`).
2. Zerwane gniazdo: połącz ponownie z rosnącym odstępem, zaczynając od samego biletu usługi. Hasło idzie w ruch dopiero, gdy bilet główny jest odrzucony.
3. Odrzucone hasło albo `loginPhase` inny niż sukces: stan „wymaga człowieka”. Żadnych dalszych prób, dopóki właściciel nie kliknie „zaloguj ponownie” albo nie zmieni hasła w ustawieniach.
4. Wyparcie przez inną sesję: jeśli serwer zamyka połączenie, bo właściciel zalogował się gdzie indziej, aplikacja ustępuje. Nie łączy się od razu, tylko próbuje ponownie co kilkanaście minut, żeby nie wyrzucać właściciela z xStation.
5. Podtrzymanie: ping według tego, co pokaże spike. Po wybudzeniu komputera i zmianie sieci od razu próba połączenia.

### Liczby

- **Wartość konta, łączny zysk**: z `xtotalbalance`.
- **Zmiana dzienna**: bieżący łączny zysk minus zysk z ostatniej próbki sprzed dzisiejszej lokalnej północy, niezależnie od tego, jak stara jest ta próbka (w poniedziałek będzie to piątkowa). Pole jest puste tylko wtedy, gdy nie ma żadnej wcześniejszej próbki. Znane ograniczenie: zamknięcie pozycji w ciągu dnia zmienia łączny zysk na otwartych pozycjach, więc tego dnia liczba będzie przekłamana.
- **Pozycje**: z listy pozycji, zysków pozycji i słownika instrumentów; kilka transakcji na tym samym instrumencie sumowanych w jeden wiersz; kolejność od największej wartości.

### Interfejs

- **Pasek, stan zwykły**: wykres (ok. 30 pt), dwie linijki małą czcionką: łączny zysk, pod nim „dziś ±X zł”. Zielony dla plusa, czerwony dla minusa.
- **Pasek, najechanie**: między wykresem a linijkami pojawia się wartość konta.
- **Pasek, kliknięcie**: menu ze stanem połączenia i czasem ostatniej aktualizacji, „zaloguj ponownie”, wyborem okresu wykresu, ustawieniami (login, hasło), zakończeniem.
- **Brak połączenia**: liczby szare, znak ostrzeżenia; w widgecie dopisek z czasem ostatnich danych.
- **Okres wykresu**: dzień, tydzień, miesiąc, wszystko. Dla paska wybierany w menu, dla widgetu w jego ustawieniach („Edytuj widget”). Domyślnie dzień.
- **Widget**: odświeżany przez aplikację po każdej próbce. System sam ogranicza częstotliwość, więc widget nie jest na żywo.

## Decyzje autora projektu (nie właściciela)

- Swift natywnie; AppKit dla elementu paska, SwiftUI dla widgetu.
- Próbki w zwykłym pliku, bez bazy danych (ok. 35 tys. próbek rocznie).
- Próbkowanie tylko przy działającym połączeniu; przerwy zostają przerwami na wykresie.
- Okresy wykresu: dzień, tydzień, miesiąc, wszystko; domyślnie dzień.
- Menu po kliknięciu, sortowanie pozycji, wygląd stanu bez połączenia.
- Sumowanie kilku transakcji na tym samym instrumencie w jeden wiersz.
- Spike jako pierwszy krok: narzędzie wiersza poleceń, które loguje się i wypisuje saldo oraz pozycje, żeby zamknąć listę nieznanych przed budową interfejsu. Hasło do pęku kluczy wpisuje sam właściciel; spike je stamtąd czyta, wykonuje najwyżej jedną próbę logowania na uruchomienie i nigdy nie wypisuje hasła ani biletów. Wynik porównuje się z otwartym xStation właściciela.
- Z rekonesansu nie zachowano surowych wiadomości, tylko ich kształty. Spike zapisuje przykładowe wiadomości (bez danych osobowych i biletów) jako dane do testów parsowania.
- Ustępowanie innej sesji, wyliczanie zmiany dziennej od ostatniej dostępnej próbki, 2FA poza zakresem.
- Makiety leżą poza folderem projektu: `/Users/filipkostecki/repos/mine/.superpowers/brainstorm/65166-1794478573/content/` (`menubar.html`, `widget.html`). Obowiązuje wariant paska z drugiego pliku i widget „C. Szeroki”.
- Projekt w `/Users/filipkostecki/repos/mine/xtb-widget`.

## Ograniczenia i ryzyka

- **Regulamin XTB.** To nieoficjalne korzystanie z prywatnego API. XTB może to zablokować albo uznać za naruszenie regulaminu. Ryzyko ponosi właściciel konta.
- **Kruchość.** Zmiana po stronie XTB może zepsuć aplikację bez ostrzeżenia. Parsowanie ma odrzucać nieznane kształty bez wywracania aplikacji i pokazywać stan błędu.
- **2FA.** Jeśli XTB je wymusi, automatyczne logowanie przestanie być możliwe; zostaje stan „wymaga człowieka”.
- **Podpisywanie.** Widget i App Group wymagają podpisanej aplikacji. Na komputerze jest Xcode 27.1, ale brak certyfikatu. Właściciel musi zalogować się do Xcode swoim Apple ID (wystarczy darmowe konto), żeby powstał certyfikat deweloperski.
- **System.** macOS 27; nie wspieramy starszych.

## Zostawione budującemu

- Struktura projektu Xcode, nazwy, format pliku próbek.
- Dokładny wygląd (czcionki, odstępy) w granicach makiet.
- Strategia odstępów przy ponownym łączeniu.
- Testy: parsowanie wiadomości na nagranych przykładach, wyliczanie zmiany dziennej, magazyn próbek, maszyna stanów sesji.

## Wiele kont (decyzja właściciela)

Aplikacja pokazuje podsumowanie wszystkich niearchiwalnych kont rzeczywistych z `accountList` (np. zwykłe i IKE): wartość konta, łączny zysk i zmiana dzienna to sumy, lista pozycji zawiera pozycje ze wszystkich kont. Subskrypcje salda, zysków i pozycji zakłada się dla każdego konta. Próbki zapisują sumy.

Decyzja autora: zakładamy, że wszystkie konta są w tej samej walucie. Spike to sprawdza; jeśli waluty się różnią, trzeba wrócić do właściciela przed budową interfejsu, bo sumowanie wymagałoby kursów.
