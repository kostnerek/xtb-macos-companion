import Foundation

/// Average exchange rates from the National Bank of Poland (table A), in PLN per unit.
/// Fetched at most every 12 hours; the last known rate is kept when a fetch fails.
@MainActor
final class ExchangeRates {
    private static let key = "nbpRates"
    private static let maxAge: TimeInterval = 12 * 3600
    private struct Cached: Codable { var rates: [String: Double]; var fetched: [String: Date] }

    private var cache: Cached = UserDefaults.standard.data(forKey: key)
        .flatMap { try? JSONDecoder().decode(Cached.self, from: $0) } ?? Cached(rates: [:], fetched: [:])

    func rates(for currencies: Set<String>) async -> [String: Double] {
        for code in currencies.subtracting(["PLN"]) {
            if let fetched = cache.fetched[code], Date().timeIntervalSince(fetched) < Self.maxAge { continue }
            if let rate = await Self.fetch(code) {
                cache.rates[code] = rate
                cache.fetched[code] = Date()
                UserDefaults.standard.set(try? JSONEncoder().encode(cache), forKey: Self.key)
            } else {
                Log.write("NBP rate for \(code) unavailable, keeping \(cache.rates[code].map { "\($0)" } ?? "none")")
            }
        }
        return cache.rates
    }

    private struct Response: Decodable { struct Rate: Decodable { let mid: Double }; let rates: [Rate] }

    private static func fetch(_ code: String) async -> Double? {
        guard let url = URL(string: "https://api.nbp.pl/api/exchangerates/rates/a/\(code.lowercased())/?format=json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(Response.self, from: data))?.rates.first?.mid
    }
}
