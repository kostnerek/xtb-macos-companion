# XTB macOS Companion

Twoje konta XTB w pasku menu i w widgecie na pulpicie macOS, bez otwierania xStation.

- **Pasek menu:** łączny zysk. Po najechaniu pokazuje też wartość konta i dzisiejszą zmianę, a po kliknięciu menu z sumami, każdym kontem i wszystkimi pozycjami.
- **Widget:** cztery rozmiary (od małego do bardzo dużego). Zysk, zmiana dzienna, wykres i lista pozycji przewijana przyciskami ▲▼.
- **Konta:** każdy rachunek handlowy (np. PLN i EUR), IKZE oraz suma wszystkich kont w złotówkach po średnim kursie NBP.
- **Ustawienia widgetu** („Edytuj widżet”): konto, okres wykresu (dzień, tydzień, miesiąc, wszystko), sortowanie (wartość, zysk %, zysk zł, nazwa), pokazywanie wartości konta.

> **Nieoficjalne.** XTB nie udostępnia publicznego API. Aplikacja czyta dane z tej samej strony, z której korzystasz w przeglądarce. Zmiana po stronie XTB może ją zepsuć bez ostrzeżenia. Korzystasz na własne ryzyko i w zgodzie z regulaminem XTB.

## Jak to działa

Co 15 minut (do zmiany w menu: **Odświeżaj co** 5, 10, 15, 30 lub 60 minut) oraz po wybudzeniu Maca aplikacja otwiera xStation 5 w ukrytym oknie WebKit, odczytuje je (ok. 20 sekund) i zamyka.

Opcje **10 s** i **30 s** to tryb na żywo: xStation zostaje otwarty w tle na rachunku złotówkowym z widokiem IKZE, a liczby są odczytywane z niego co 10 lub 30 sekund. Zajmuje to więcej pamięci i prądu. Pozostałe rachunki odświeżają się wtedy co 15 minut, a historia wykresu też zapisuje się co 15 minut.

Każdy odczyt przebiega tak:

1. Jeśli sesja wygasła, loguje się loginem i hasłem z pęku kluczy. Gdy XTB poprosi o kod SMS, aplikacja przestaje próbować sama i prosi o zalogowanie się w oknie.
2. Odczytuje wiadomości, które strona dostaje przez swoje połączenie (saldo, pozycje, zyski, nazwy instrumentów), a nie same piksele.
3. Strona przesyła dane tylko otwartego rachunku, więc aplikacja przełącza po kolei rachunki w przełączniku strony.
4. IKZE nie przychodzi tym kanałem, więc aplikacja otwiera jego widok i odczytuje z niego wartość, zysk i pozycje.
5. Zapisuje migawkę i próbkę historii każdego konta we wspólnym kontenerze App Group, z którego czyta widget.

Okno jest wyciszone, a po każdym odświeżeniu zamykane.

## Wymagania

- macOS 15 lub nowszy
- Xcode i [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple ID dodane w Xcode (Settings → Accounts). Darmowe konto wystarczy. Bez podpisu pasek menu działa, ale widget się nie zainstaluje.

## Budowanie

1. W `project.yml` wpisz ID swojego zespołu w `DEVELOPMENT_TEAM`. Znajdziesz je w polu `OU` certyfikatu:
   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```
2. Wygeneruj projekt i zbuduj aplikację:
   ```sh
   xcodegen
   xcodebuild -project XTBBar.xcodeproj -scheme XTBBar -configuration Release -allowProvisioningUpdates build
   ```
3. Skopiuj `XTBBar.app` z katalogu produktów do `/Applications` i uruchom. Przy pierwszym uruchomieniu aplikacja dopisze się do autostartu. Wyłączysz to w menu: **Uruchamiaj przy logowaniu**.

## Pierwsze uruchomienie

1. Ikona XTB w pasku → **Login i hasło…**. Hasło trafia tylko do pęku kluczy.
2. Jeśli XTB wymaga kodu SMS: **Zaloguj się w oknie…**, wpisz kod. Dalej sesja odnawia się sama.
3. Prawy klik na pulpicie → **Edytuj widżety** → wyszukaj „XTB”.
4. Ikonę w pasku możesz przesunąć, przeciągając ją z wciśniętym ⌘. Pozycja jest zapamiętywana.

## Prywatność

- Hasło jest tylko w pęku kluczy, nigdy w plikach ani w logach.
- Dane kont zostają na Twoim Macu: w kontenerze `~/Library/Group Containers/<TEAM>.pl.local.xtbbar`. Log diagnostyczny jest w `~/Library/Application Support/XTBBar/log.txt` i nie zawiera hasła.
- Jedyne połączenia poza XTB to pobieranie średniego kursu walut z publicznego API NBP (`api.nbp.pl`), najwyżej co 12 godzin.

## Struktura

| Katalog | Zawartość |
|---|---|
| `Sources/XTBKit` | Dekodowanie wiadomości xStation, migawki per konto, suma kont, historia próbek |
| `App` | Aplikacja paska menu: ukryte okno xStation, logowanie, menu, kursy NBP |
| `Widget` | Rozszerzenie WidgetKit |
| `Shared` | Kod wspólny dla aplikacji i widgetu: wspólny kontener, formatowanie kwot, wykres |
| `Tests/XTBKitTests` | Testy XTBKit (`swift test`) |

## Ograniczenia

- Interfejs i odczyt IKZE zakładają polską wersję xStation.
- Odczyt IKZE opiera się na wyglądzie strony i jest najbardziej podatny na zmiany po stronie XTB. Gdy przestanie działać, pozostałe konta działają dalej.
- Suma kont przelicza waluty po średnim kursie NBP, więc może się nieznacznie różnić od „Wszystkie konta” w xStation.
- Widget odświeża się po każdym odczycie, ale częstotliwość ogranicza system, więc nie działa na żywo.
