import Foundation

/// Which Taiwan exchange a symbol trades on. The distinction matters for every
/// endpoint we touch: MIS wants a `tse_`/`otc_` prefix, and the daily-history
/// APIs live on entirely different hosts (twse.com.tw vs tpex.org.tw).
enum TWExchange: String, Codable {
    case twse   // 上市
    case tpex   // 上櫃

    /// The prefix MIS uses in its `ex_ch` parameter.
    var misPrefix: String { self == .twse ? "tse" : "otc" }
}

/// A Taiwan-market instrument, parsed from the many spellings a watchlist or a
/// strategy plan might use.
///
/// Accepted inputs (case-insensitive):
/// - `TWSE-2330`, `TPEX-3491` — the form the strategy plan uses
/// - `2330.TW`, `3491.TWO` — the Yahoo form, so a user's existing watchlist
///   entry keeps working after this glance learned about Taiwan
/// - `2330` — a bare code, assumed 上市 (the common case; a 上櫃 code entered
///   bare will simply return no data, which the popover surfaces)
/// - `TAIEX` / `^TWII` — the weighted index, used for the plan's market gate
struct TWSymbol: Hashable {
    /// The four-or-more digit code, or `t00` for the index.
    let code: String
    let exchange: TWExchange

    /// True for the 加權指數 pseudo-symbol, which has a quote but no history.
    var isIndex: Bool { code == "t00" }

    /// The `ex_ch` token MIS expects, e.g. `tse_2330.tw`.
    var misKey: String { "\(exchange.misPrefix)_\(code).tw" }

    /// The canonical spelling we store and display, e.g. `TWSE-2330`.
    var canonical: String { isIndex ? "TAIEX" : "\(exchange.rawValue.uppercased())-\(code)" }

    static let taiex = TWSymbol(code: "t00", exchange: .twse)

    /// Parses any of the accepted spellings. Returns nil for anything that
    /// isn't a Taiwan symbol — that's the signal for `StocksPlugin` to route it
    /// to the Yahoo/Finnhub providers instead.
    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty else { return nil }

        if s == "TAIEX" || s == "^TWII" || s == "TWSE-T00" {
            self = .taiex
            return
        }

        // TWSE-2330 / TPEX-3491
        if let dash = s.firstIndex(of: "-") {
            let prefix = String(s[s.startIndex..<dash])
            let rest = String(s[s.index(after: dash)...])
            guard let ex = TWExchange(rawValue: prefix.lowercased()),
                  Self.isCode(rest) else { return nil }
            code = rest
            exchange = ex
            return
        }

        // 2330.TW / 3491.TWO
        if let dot = s.firstIndex(of: ".") {
            let head = String(s[s.startIndex..<dot])
            let tail = String(s[s.index(after: dot)...])
            guard Self.isCode(head) else { return nil }
            switch tail {
            case "TW": code = head; exchange = .twse
            case "TWO": code = head; exchange = .tpex
            default: return nil
            }
            return
        }

        // Bare code. Only digits qualify, so US tickers fall through to Yahoo.
        guard Self.isCode(s) else { return nil }
        code = s
        exchange = .twse
    }

    private init(code: String, exchange: TWExchange) {
        self.code = code
        self.exchange = exchange
    }

    /// Taiwan listing codes are 4–6 digits (4 for ordinary shares, longer for
    /// warrants and ETFs). Requiring all-digits is what keeps `AAPL` out.
    private static func isCode(_ s: String) -> Bool {
        (4...6).contains(s.count) && s.allSatisfy(\.isNumber)
    }
}

/// The Taipei trading calendar, to the precision this glance needs.
///
/// Deliberately does *not* model market holidays: there's no free, stable feed
/// for them, and getting one wrong would silently stop alerts on a real trading
/// day — the expensive failure. Treating a holiday as open is the cheap failure
/// instead: MIS returns the previous session's stale data, no level crosses,
/// and nothing fires. The cost is a handful of wasted requests on ~15 days a
/// year, which the rate gate absorbs without noticing.
enum TWMarketClock {
    static let timeZone = TimeZone(identifier: "Asia/Taipei")!

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }()

    /// Minutes since midnight Taipei, or nil if the date can't be decomposed.
    private static func minutes(_ date: Date) -> Int? {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return nil }
        return h * 60 + m
    }

    private static func isWeekday(_ date: Date) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd != 1 && wd != 7
    }

    /// 09:00–13:30 on a weekday. The window we're willing to spend requests in.
    static func isOpen(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return m >= 9 * 60 && m <= 13 * 60 + 30
    }

    /// 13:25–13:30 — the last five minutes, when the running price is a good
    /// enough proxy for the close that a 收盤 condition can be provisionally
    /// evaluated. The engine still re-confirms once after the bell.
    static func isCloseWindow(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return m >= 13 * 60 + 25 && m <= 13 * 60 + 30
    }

    /// True once the session has ended for the day (and it was a weekday), the
    /// window in which a 收盤 condition can be settled and daily history is
    /// worth fetching. 14:00 rather than 13:30 so the exchange has published.
    static func isAfterClose(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return m >= 14 * 60
    }

    /// `yyyy-MM-dd` in Taipei — the key everything per-day is bucketed under
    /// (alert dedupe, once-a-day history fetches).
    static func tradingDay(_ now: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
