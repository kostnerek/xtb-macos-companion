import AppIntents
import SwiftUI
import WidgetKit
import XTBKit

/// The chart period, chosen in "Edit Widget".
enum WidgetRange: String, AppEnum {
    case day, week, month, all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Okres wykresu"
    static let caseDisplayRepresentations: [WidgetRange: DisplayRepresentation] = [
        .day: "Dzień", .week: "Tydzień", .month: "Miesiąc", .all: "Wszystko",
    ]

    var chartRange: ChartRange { ChartRange(rawValue: rawValue) ?? .day }
}

/// Order of the positions list, chosen in "Edit Widget". Numbers go largest first, names A to Z.
enum PositionSort: String, AppEnum {
    case value, profitPercent, profit, name

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sortowanie"
    static let caseDisplayRepresentations: [PositionSort: DisplayRepresentation] = [
        .value: "Wartość", .profitPercent: "Zysk %", .profit: "Zysk zł", .name: "Nazwa",
    ]

    func sorted(_ rows: [PositionRow]) -> [PositionRow] {
        switch self {
        case .value: rows.sorted { $0.value > $1.value }
        case .profitPercent: rows.sorted { $0.profitPercent > $1.profitPercent }
        case .profit: rows.sorted { $0.profit > $1.profit }
        case .name: rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

/// One account, or all accounts summed; the list comes from what the app last saw.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Konto"
    static let defaultQuery = AccountQuery()

    let id: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(SharedStore.label(for: id))") }
}

struct AccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [AccountEntity] { identifiers.map(AccountEntity.init) }

    func suggestedEntities() async throws -> [AccountEntity] {
        ([SharedStore.allAccounts] + SharedStore.readAccounts().map(\.accountNo)).map(AccountEntity.init)
    }

    func defaultResult() async -> AccountEntity? { AccountEntity(id: SharedStore.allAccounts) }
}

struct RangeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Ustawienia widgetu"

    @Parameter(title: "Konto")
    var account: AccountEntity?

    @Parameter(title: "Okres wykresu", default: .day)
    var range: WidgetRange

    @Parameter(title: "Sortowanie", default: .value)
    var sort: PositionSort

    @Parameter(title: "Pokazuj wartość konta", default: false)
    var showEquity: Bool
}

/// Widgets cannot scroll, so the positions list is paged; the ▲▼ buttons run this intent.
/// The page is kept in the App Group's defaults, per account and widget size.
struct ShowPositionsPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Przewiń pozycje"
    static let isDiscoverable = false

    static let defaults = (Bundle.main.object(forInfoDictionaryKey: "XTBAppGroup") as? String)
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard

    @Parameter(title: "Klucz") var key: String
    @Parameter(title: "Strona") var page: Int

    init() {}

    init(key: String, page: Int) {
        self.key = key
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        Self.defaults.set(max(0, page), forKey: key)
        return .result()
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let display: Display
    let sort: PositionSort
    let showEquity: Bool
    let account: String
}

/// Reads what the app wrote; never touches the network. The app asks for a reload after each
/// refresh; the widget also reloads itself shortly after each scheduled refresh, so a missed
/// reload request never leaves it showing old data for long.
struct Provider: AppIntentTimelineProvider {
    private func entry(_ configuration: RangeIntent, at date: Date) -> Entry {
        let account = configuration.account?.id ?? SharedStore.allAccounts
        return Entry(date: date, display: Display(store: SharedStore.store(for: account), range: configuration.range.chartRange, now: date),
                     sort: configuration.sort, showEquity: configuration.showEquity, account: account)
    }

    func placeholder(in context: Context) -> Entry { entry(RangeIntent(), at: Date()) }

    func snapshot(for configuration: RangeIntent, in context: Context) async -> Entry {
        entry(configuration, at: Date())
    }

    func timeline(for configuration: RangeIntent, in context: Context) async -> Timeline<Entry> {
        let now = entry(configuration, at: Date())
        var entries = [now]
        if !now.display.stale, let updated = now.display.snapshot?.updatedAt {
            entries.append(entry(configuration, at: updated.addingTimeInterval(Display.staleAfter + 1)))
        }
        return Timeline(entries: entries, policy: .after(nextSampleDate(after: Date(), every: RefreshInterval.sampleSeconds).addingTimeInterval(90)))
    }
}

/// The account value is shown only when switched on in "Edit Widget". Small shows only the
/// summary and chart; medium puts a few positions beside them. Extra large is layout "C. Szeroki": summary and
/// chart on the left, positions on the right. Large (the size Notification Center accepts) stacks
/// the same parts: summary, chart, then positions.
struct PortfolioView: View {
    let display: Display
    let sort: PositionSort
    let showEquity: Bool
    let account: String
    @Environment(\.widgetFamily) private var family

    private func color(_ amount: Double) -> Color {
        display.stale ? .secondary : (amount < 0 ? .red : .green)
    }

    var body: some View {
        if let snapshot = display.snapshot {
            Group {
                switch family {
                case .systemSmall:
                    summaryAndChart(snapshot)
                case .systemMedium:
                    sideBySide(snapshot, chartShare: 0.4, maxRows: 5)
                case .systemLarge:
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .top) {
                            summary(snapshot)
                            Spacer(minLength: 8)
                            staleNote(snapshot)
                        }
                        chart(snapshot).frame(height: 44).padding(.vertical, 8)
                        positions(snapshot, maxRows: 7)
                        Spacer(minLength: 0)
                    }
                default:
                    sideBySide(snapshot, chartShare: 0.34, maxRows: 13)
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        } else {
            Text("Brak danych. Uruchom XTBBar i zaloguj się.")
                .foregroundStyle(.secondary)
        }
    }

    private func summaryAndChart(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            summary(snapshot)
            chart(snapshot).padding(.top, 8)
            staleNote(snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Summary and chart in a narrow column on the left (`chartShare` of the width), positions on the right.
    private func sideBySide(_ snapshot: Snapshot, chartShare: CGFloat, maxRows: Int) -> some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 16
            let left = (geometry.size.width - spacing) * chartShare
            HStack(alignment: .top, spacing: spacing) {
                summaryAndChart(snapshot).frame(width: left)
                positions(snapshot, maxRows: maxRows).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private func summary(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(SharedStore.label(for: account))
                .font(.caption)
                .foregroundStyle(.secondary)
            if showEquity {
                Text(Money.plain(snapshot.equity, snapshot.currency))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(display.stale ? .secondary : .primary)
            }
            Text(Money.signed(snapshot.profit, snapshot.currency))
                .font(showEquity ? .system(size: 12) : .system(size: 24, weight: .bold))
                .foregroundStyle(color(snapshot.profit))
            Text(Money.percent(snapshot.profitPercent))
                .foregroundStyle(color(snapshot.profit))
            if let change = display.dailyChange {
                Text("dziś " + Money.signed(change, snapshot.currency))
                    .foregroundStyle(color(change))
            }
        }
    }

    private func chart(_ snapshot: Snapshot) -> some View {
        Sparkline(segments: display.chart)
            .stroke(color(snapshot.profit), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }

    @ViewBuilder
    private func staleNote(_ snapshot: Snapshot) -> some View {
        if display.stale {
            Label("Dane z " + dataTime(snapshot.updatedAt), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, family == .systemLarge ? 0 : 6)
        }
    }

    /// Name, then value (or profit in zł when sorted by it, so the order is visible), then profit %.
    /// Shows `maxRows` lines; when there are more positions, the last line pages through them.
    private func positions(_ snapshot: Snapshot, maxRows: Int) -> some View {
        let rows = sort.sorted(snapshot.positions)
        let pageSize = rows.count > maxRows ? max(1, maxRows - 1) : max(1, rows.count)
        let pages = max(1, (rows.count + pageSize - 1) / pageSize)
        let key = "positionsPage.\(account).\(family)"
        let page = min(ShowPositionsPageIntent.defaults.integer(forKey: key), pages - 1)
        let start = page * pageSize, end = min(rows.count, start + pageSize)
        return VStack(spacing: 0) {
            ForEach(Array(rows[start..<end].enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 8) {
                    Text(row.name).lineLimit(1)
                    Spacer(minLength: 4)
                    if sort == .profit {
                        Text(Money.signed(row.profit, snapshot.currency)).foregroundStyle(color(row.profit))
                    } else {
                        Text(Money.plain(row.value, snapshot.currency))
                    }
                    Text(Money.percent(row.profitPercent))
                        .foregroundStyle(color(row.profit))
                        .frame(width: 52, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
            if pages > 1 {
                Divider()
                HStack(spacing: 12) {
                    Text("\(start + 1)–\(end) z \(rows.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(intent: ShowPositionsPageIntent(key: key, page: page - 1)) { Image(systemName: "chevron.up") }
                        .disabled(page == 0)
                    Button(intent: ShowPositionsPageIntent(key: key, page: page + 1)) { Image(systemName: "chevron.down") }
                        .disabled(page == pages - 1)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
        }
    }

    private func dataTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}

@main
struct XTBWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "XTBWidget", intent: RangeIntent.self, provider: Provider()) { entry in
            PortfolioView(display: entry.display, sort: entry.sort, showEquity: entry.showEquity, account: entry.account)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("XTB")
        .description("Łączny zysk, zmiana dzienna i otwarte pozycje.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}
