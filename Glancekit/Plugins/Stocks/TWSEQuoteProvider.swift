import Foundation

/// Realtime Taiwan quotes from the exchange's own MIS feed — the same endpoint
/// `mlouielu/twstock` and `Asoul/tsrtc` use.
///
/// The one design decision that matters here: **`ex_ch` is pipe-joined, so the
/// whole watchlist costs a single request.** Both reference projects do this,
/// and it's what makes a 3-requests-per-5-seconds budget comfortable rather
/// than tight — adding a tenth symbol costs nothing. tsrtc polls this every 3
/// seconds; we don't, both because the response's own `userDelay: 5000` says
/// not to and because a menu-bar glance has no use for sub-minute resolution.
struct TWSEQuoteProvider: QuoteProvider {
    var client = NetworkClient()
    var gate: TWRateGate = .shared

    /// MIS caps how much it will return in one query. Well above any sane
    /// watchlist, but a plan with a long tail shouldn't silently truncate, so
    /// oversized requests are chunked (each chunk still goes through the gate).
    private static let maxPerRequest = 40

    /// `fetchQuotes` takes the watchlist spellings; non-Taiwan entries are
    /// dropped here and picked up by the Yahoo/Finnhub path instead.
    func fetchQuotes(_ symbols: [String]) async throws -> [StockQuote] {
        let parsed = symbols.compactMap { raw in TWSymbol(raw).map { (raw, $0) } }
        guard !parsed.isEmpty else { return [] }

        var out: [StockQuote] = []
        for chunk in stride(from: 0, to: parsed.count, by: Self.maxPerRequest).map({
            Array(parsed[$0..<min($0 + Self.maxPerRequest, parsed.count)])
        }) {
            out += try await fetchChunk(chunk)
        }
        return out
    }

    private func fetchChunk(_ chunk: [(String, TWSymbol)]) async throws -> [StockQuote] {
        let exCh = chunk.map { $0.1.misKey }.joined(separator: "|")
        // The `_` cache-buster is what tsrtc sends; MIS serves a cached body
        // without it. `delay=0` asks for the undelayed feed.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let encoded = exCh.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? exCh
        let url = "https://mis.twse.com.tw/stock/api/getStockInfo.jsp?ex_ch=\(encoded)&json=1&delay=0&_=\(stamp)"

        await gate.acquire(.mis)
        let response = try await client.get(MISResponse.self, from: url, headers: [
            // MIS is picky about being called like a browser. Without a Referer
            // it intermittently answers with an empty msgArray.
            "Referer": "https://mis.twse.com.tw/stock/index.jsp",
            "Accept": "application/json, text/javascript, */*"
        ])

        guard response.rtcode == "0000" else {
            throw NetworkClient.NetworkError.decoding(
                "MIS rtcode \(response.rtcode ?? "?"): \(response.rtmessage ?? "unknown")")
        }

        // Key the response by MIS key so results map back to the exact watchlist
        // spelling the user typed, whatever that was.
        var byKey: [String: MISEntry] = [:]
        for entry in response.msgArray ?? [] {
            if let ex = entry.ex, let c = entry.c { byKey["\(ex)_\(c).tw"] = entry }
        }

        return chunk.compactMap { raw, symbol in
            byKey[symbol.misKey].flatMap { quote(from: $0, displayedAs: raw) }
        }
    }

    private func quote(from e: MISEntry, displayedAs symbol: String) -> StockQuote? {
        let previousClose = num(e.y) ?? 0
        // `z` is the last matched price *for the 5-second snapshot MIS is
        // currently serving*, and it is "-" in any window where no match
        // happened — which near the open, or on a thin stock, is most windows.
        // Measured on 2330, 2026-07-20: `z=2320.0000, tv=1` at 09:22:00 and
        // `z="-", tv="-"` at 09:22:05, with accumulated volume still climbing
        // through both. So a blank `z` means "no trade in this window", never
        // "no trade today", and the correct reading is the last one we saw.
        //
        // That carry-forward can't happen here — this struct is rebuilt on
        // every fetch — so `tradePrice` reports whether this snapshot carried a
        // real match and `StocksPlugin` holds the memory. It is also why the
        // fallbacks below must not be mistaken for a traded price: the exchange's
        // own front end (vendored in Asoul/tsrtc as `ctrl.fibest.js`) guards its
        // price update with `item.z!="-"` and otherwise leaves the previous
        // number on screen, rather than substituting anything from the book.
        let tradePrice = num(e.z) ?? num(e.pz)

        // Only reached before any trade is known: the app opening mid-session
        // onto a blank window, or a stock that has not matched yet today. The
        // five-deep book (`b` bids, `a` asks, best first) is the closest thing
        // to a price at that point, then yesterday's close. Bid rather than the
        // bid/ask midpoint — TWSE ticks are coarse (5.00 at 2330's level), so a
        // midpoint invents an off-tick number no trade could occur at, and it
        // errs to the conservative side of a stop-loss. A bogus 0 stays out
        // entirely; in the alert engine it would read as every downside level
        // crossing at once.
        guard let price = tradePrice ?? best(e.b) ?? best(e.a)
                ?? (previousClose > 0 ? previousClose : nil) else {
            return nil
        }

        return StockQuote(
            symbol: symbol,
            price: price,
            tradePrice: tradePrice,
            previousClose: previousClose,
            currency: "TWD",
            series: [],
            name: e.n,
            volumeLots: num(e.v),
            open: num(e.o),
            dayHigh: num(e.h),
            dayLow: num(e.l),
            limitUp: num(e.u),
            limitDown: num(e.w),
            quotedAt: e.tlong.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    /// MIS sends every number as a string, and uses "-" for "no value". Parsing
    /// that as 0 is the bug that would fire a stop-loss alert on an untraded
    /// stock, so absence stays absent.
    private func num(_ s: String?) -> Double? {
        guard let s, s != "-", !s.isEmpty else { return nil }
        return Double(s)
    }

    /// Best price from one side of the book. MIS packs the five levels into a
    /// single underscore-joined string with a trailing separator
    /// (`"2335.0000_2340.0000_…_"`), best first, and sends an empty string when
    /// that side is empty — as it always is for the index, which has no book.
    private func best(_ side: String?) -> Double? {
        side?.split(separator: "_").first.flatMap { num(String($0)) }
    }
}

// MARK: - Wire format

/// Only the fields we use. MIS returns ~40 per entry, including several whose
/// keys are punctuation (`@`, `#`, `%`, `^`) — left undecoded on purpose.
private struct MISResponse: Decodable {
    let msgArray: [MISEntry]?
    let rtcode: String?
    let rtmessage: String?
}

private struct MISEntry: Decodable {
    let c: String?      // code, e.g. "2330"
    let n: String?      // short name, e.g. 台積電
    let ex: String?     // "tse" | "otc"
    let z: String?      // last traded price
    let pz: String?     // previous matched price (fallback when z is "-")
    let b: String?      // bid book, five levels, "_"-joined, highest first
    let a: String?      // ask book, five levels, "_"-joined, lowest first
    let y: String?      // previous close
    let o: String?      // open
    let h: String?      // day high
    let l: String?      // day low
    let v: String?      // accumulated volume, in 張
    let tv: String?     // volume of the last match, in 張
    let u: String?      // limit up
    let w: String?      // limit down
    let t: String?      // exchange time, "HH:mm:ss"
    let tlong: String?  // exchange time, epoch ms
}
