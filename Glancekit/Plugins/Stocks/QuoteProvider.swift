import Foundation

/// A single stock quote plus an optional intraday series for the sparkline.
///
/// The fields below `series` are all optional additions carrying detail only
/// some sources provide — Taiwan's MIS feed fills in every one of them, Yahoo
/// fills in most, Finnhub only a few. They default, so a provider states what it
/// actually knows and nothing else.
struct StockQuote: Identifiable, Equatable {
    /// The watchlist spelling this quote answers to — whatever the user typed.
    let symbol: String
    /// Which market it trades in, which decides its currency, its volume unit
    /// and, not least, which direction is drawn in red.
    var market: Market
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

    /// Display name from the exchange, e.g. 台積電 / Apple Inc. Nil when the
    /// source has none.
    var name: String? = nil
    /// Accumulated volume for the session, in whatever `volumeUnit` says. The
    /// unit is carried rather than normalized because the two readings are not
    /// interchangeable: a Taiwan strategy plan's volume conditions are written
    /// in 張, and silently converting to shares would compare 2,602 against
    /// 2,602,000.
    var volume: Double? = nil
    var volumeUnit: Market.VolumeUnit = .shares
    var open: Double? = nil
    var dayHigh: Double? = nil
    var dayLow: Double? = nil
    /// The session's price limits (漲停/跌停 in Taiwan, ストップ高/安 in Japan),
    /// where the exchange publishes them. Carried rather than recomputed because
    /// exchanges apply their own rounding to the tick grid, and a locked stock is
    /// precisely the case where being one tick off would misreport it as still
    /// trading. US equities have no daily limit, so this stays nil there.
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

    /// Volume in 張, and only where that is genuinely the unit reported. The
    /// strategy engine reads this, so a US quote's share count can never be
    /// mistaken for a lot count by a rule written for Taiwan.
    var volumeLots: Double? { volumeUnit == .lots ? volume : nil }
}

/// The pluggable seam for stock data. Taiwan symbols go to the exchange's own
/// MIS feed; US and Japanese symbols go to Yahoo, or to Finnhub once the user
/// supplies a key. New providers (IEX, Polygon, …) drop in behind this protocol.
protocol QuoteProvider {
    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote]
}

// MARK: - Yahoo (keyless default, US + Japan)

/// Uses Yahoo's public v8 chart endpoint (no API key). Unofficial and can
/// change without notice — hence the Finnhub fallback for US names.
///
/// This is the multi-market path: Yahoo spells a Tokyo listing `7203.T` and a
/// Taipei one `2330.TW`, so `MarketSymbol.yahooSymbol` is the only place that
/// has to know the difference.
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
        let parsed = MarketSymbol(symbol)
        let wire = parsed?.yahooSymbol ?? symbol
        let market = parsed?.market ?? .us
        let encoded = wire.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? wire
        let url = "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=1d&interval=5m"
        let response = try await client.get(YahooChartResponse.self, from: url)
        guard let result = response.chart.result?.first else {
            throw NetworkClient.NetworkError.decoding("no chart result for \(symbol)")
        }
        let meta = result.meta
        let closes = result.indicators?.quote?.first?.close?.compactMap { $0 } ?? []
        return StockQuote(
            symbol: symbol,
            market: market,
            price: meta.regularMarketPrice ?? closes.last ?? 0,
            previousClose: meta.chartPreviousClose ?? meta.previousClose ?? 0,
            currency: meta.currency ?? market.currencyCode,
            series: closes,
            name: meta.shortName ?? meta.longName,
            // Yahoo reports every market's volume in shares, including Taiwan's
            // — so it is tagged as shares whatever the symbol, and a Taiwan
            // plan's 張 conditions correctly find nothing to measure here.
            volume: meta.regularMarketVolume,
            volumeUnit: .shares,
            dayHigh: meta.regularMarketDayHigh,
            dayLow: meta.regularMarketDayLow,
            quotedAt: meta.regularMarketTime.map { Date(timeIntervalSince1970: $0) }
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
        let shortName: String?
        let longName: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
        let regularMarketDayHigh: Double?
        let regularMarketDayLow: Double?
        let regularMarketVolume: Double?
        let regularMarketTime: Double?
    }
    struct Indicators: Decodable { let quote: [Quote]? }
    struct Quote: Decodable { let close: [Double?]? }
    let chart: Chart
}

// MARK: - Finnhub (key required, US only)

/// Uses Finnhub's `/quote` endpoint. Requires an API key stored in
/// `CredentialStore` under `finnhub.apiKey`. No intraday series (keeps the free
/// tier light), so sparklines are empty for Finnhub-sourced quotes.
///
/// Used only for US symbols. Finnhub's free tier does not cover Taiwanese or
/// Japanese equities, and a provider that returns an empty quote for them would
/// look like a dead feed rather than an unsupported market — so those symbols
/// stay on Yahoo even when a key is present.
struct FinnhubQuoteProvider: QuoteProvider {
    var apiKey: String
    var client = NetworkClient()

    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote] {
        var results: [StockQuote] = []
        for symbol in symbols {
            let wire = MarketSymbol(symbol)?.code ?? symbol
            let encoded = wire.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? wire
            let url = "https://finnhub.io/api/v1/quote?symbol=\(encoded)&token=\(apiKey)"
            if let q = try? await client.get(FinnhubQuote.self, from: url) {
                results.append(StockQuote(
                    symbol: symbol,
                    market: .us,
                    price: q.c,
                    previousClose: q.pc,
                    currency: "USD",
                    series: [],
                    open: q.o,
                    dayHigh: q.h,
                    dayLow: q.l,
                    quotedAt: q.t.map { Date(timeIntervalSince1970: $0) }
                ))
            }
        }
        return results
    }

    private struct FinnhubQuote: Decodable {
        let c: Double   // current
        let pc: Double  // previous close
        let o: Double?  // open
        let h: Double?  // day high
        let l: Double?  // day low
        let t: Double?  // quote time, epoch seconds
    }
}
