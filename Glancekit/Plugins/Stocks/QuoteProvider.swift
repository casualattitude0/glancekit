import Foundation

/// A single stock quote plus an optional intraday series for the sparkline.
///
/// The fields below `series` are all optional additions carrying detail only
/// some sources provide — the Taiwan MIS feed fills them in, Yahoo and Finnhub
/// leave them nil. They default, so every existing construction site still
/// compiles unchanged.
struct StockQuote: Identifiable, Equatable {
    let symbol: String
    var price: Double
    /// `price` when it came from an actual match, nil when it was inferred
    /// (an order-book stand-in, or yesterday's close). Taiwan's MIS feed blanks
    /// its traded-price field in any 5-second window without a trade, so this
    /// is what lets `StocksPlugin` hold the last real print across those gaps
    /// instead of showing a number no one traded at. Sources that always quote
    /// a real trade (Yahoo, Finnhub) leave it nil and simply don't use it.
    var tradePrice: Double? = nil
    var previousClose: Double
    var currency: String
    /// Intraday closes, oldest → newest, used to draw the sparkline.
    var series: [Double]

    /// Display name from the exchange, e.g. 台積電. Nil when the source has none.
    var name: String? = nil
    /// Accumulated volume for the session, in 張 (lots). The plan's volume
    /// conditions are all quoted in 張, so it's stored in that unit, not shares.
    var volumeLots: Double? = nil
    var open: Double? = nil
    var dayHigh: Double? = nil
    var dayLow: Double? = nil
    /// The session's price limits (漲停/跌停), ±10% of the previous close on
    /// TWSE. Carried rather than recomputed because the exchange applies its
    /// own rounding to the tick grid, and a locked stock is precisely the case
    /// where being one tick off would misreport it as still trading.
    var limitUp: Double? = nil
    var limitDown: Double? = nil
    /// Best bid and ask. Kept because they are the only part of a Taiwan quote
    /// that stays live while `tradePrice` is blank, which makes them the check
    /// on whether a carried-forward trade is still telling the truth.
    var bid: Double? = nil
    var ask: Double? = nil
    /// When the exchange says this quote was struck (not when we fetched it) —
    /// the difference matters for telling a live tick from a stale one.
    var quotedAt: Date? = nil

    var id: String { symbol }
    var change: Double { price - previousClose }
    var changePercent: Double {
        previousClose == 0 ? 0 : (change / previousClose) * 100
    }
    var isUp: Bool { change >= 0 }
}

/// The pluggable seam for stock data. Yahoo is the keyless default; Finnhub is
/// the reliability upgrade once the user supplies a key. New providers (IEX,
/// Polygon, …) drop in behind this protocol.
protocol QuoteProvider {
    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote]
}

// MARK: - Yahoo (keyless default)

/// Uses Yahoo's public v8 chart endpoint (no API key). Unofficial and can
/// change without notice — hence the Finnhub fallback.
struct YahooQuoteProvider: QuoteProvider {
    var client = NetworkClient()

    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote] {
        var results: [StockQuote] = []
        // One request per symbol keeps parsing simple and avoids batch-endpoint
        // auth requirements. Watchlists are small, so this is fine.
        for symbol in symbols {
            if let quote = try? await fetchOne(symbol) {
                results.append(quote)
            }
        }
        return results
    }

    private func fetchOne(_ symbol: String) async throws -> StockQuote {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let url = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m"
        let response = try await client.get(YahooChartResponse.self, from: url)
        guard let result = response.chart.result?.first else {
            throw NetworkClient.NetworkError.decoding("no chart result for \(symbol)")
        }
        let meta = result.meta
        let closes = result.indicators?.quote?.first?.close?.compactMap { $0 } ?? []
        return StockQuote(
            symbol: symbol,
            price: meta.regularMarketPrice ?? closes.last ?? 0,
            previousClose: meta.chartPreviousClose ?? meta.previousClose ?? 0,
            currency: meta.currency ?? "USD",
            series: closes
        )
    }
}

// Minimal Codable shapes for the Yahoo v8 chart payload.
private struct YahooChartResponse: Decodable {
    struct Chart: Decodable { let result: [Result]? }
    struct Result: Decodable {
        let meta: Meta
        let indicators: Indicators?
    }
    struct Meta: Decodable {
        let currency: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
    }
    struct Indicators: Decodable { let quote: [Quote]? }
    struct Quote: Decodable { let close: [Double?]? }
    let chart: Chart
}

// MARK: - Finnhub (key required, more reliable)

/// Uses Finnhub's `/quote` endpoint. Requires an API key stored in `CredentialStore`
/// under `finnhub.apiKey`. No intraday series (keeps the free tier light), so
/// sparklines are empty for Finnhub-sourced quotes.
struct FinnhubQuoteProvider: QuoteProvider {
    var apiKey: String
    var client = NetworkClient()

    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote] {
        var results: [StockQuote] = []
        for symbol in symbols {
            let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? symbol
            let url = "https://finnhub.io/api/v1/quote?symbol=\(encoded)&token=\(apiKey)"
            if let q = try? await client.get(FinnhubQuote.self, from: url) {
                results.append(StockQuote(
                    symbol: symbol,
                    price: q.c,
                    previousClose: q.pc,
                    currency: "USD",
                    series: []
                ))
            }
        }
        return results
    }

    private struct FinnhubQuote: Decodable {
        let c: Double   // current
        let pc: Double  // previous close
    }
}
