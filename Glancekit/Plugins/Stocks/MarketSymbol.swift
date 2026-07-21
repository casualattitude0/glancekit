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

/// An instrument in any market this glance quotes, parsed from the many
/// spellings a watchlist, a portfolio export or a strategy plan might use.
///
/// Accepted inputs (case-insensitive):
///
/// **Taiwan**
/// - `TWSE-2330`, `TPEX-3491` — the form the strategy plan uses
/// - `2330.TW`, `3491.TWO` — the Yahoo form
/// - `2330` — a bare code, assumed 上市 (the common case; a 上櫃 code entered
///   bare will simply return no data, which the popover surfaces)
/// - `TAIEX` / `^TWII` — the weighted index, used for the plan's market gate
///
/// **United States**
/// - `AAPL`, `BRK.B` — a bare ticker; letters are what distinguish it
/// - `US-AAPL` — the explicit form, for anything ambiguous
/// - `SPX` / `^GSPC`, `NDX` / `^IXIC`, `DJI` / `^DJI` — indices
///
/// **Japan**
/// - `7203.T` — the Yahoo form
/// - `TSE-7203`, `JP-7203` — explicit forms
/// - `N225` / `^N225` — the Nikkei 225
///
/// The one rule worth stating out loud: **a bare four-digit code is Taiwan, not
/// Japan.** Both markets number their listings that way, so there is no reading
/// of `7203` that is right for everyone — and this glance's existing watchlists,
/// plans and portfolios are all full of bare Taiwan codes that must keep
/// working. Japanese codes therefore have to be spelled out, which the parse
/// error in the popover says when one isn't.
struct MarketSymbol: Hashable, Sendable {
    let market: Market
    /// The exchange's own code — `2330`, `AAPL`, `7203` — or an index pseudo-code.
    let code: String
    /// Taiwan only: which of the two exchanges. Nil everywhere else.
    let exchange: TWExchange?
    /// True for an index pseudo-symbol, which has a quote but no daily history
    /// and no order book.
    let isIndex: Bool

    // MARK: - Well-known indices

    static let taiex = MarketSymbol(market: .tw, code: "t00", exchange: .twse, isIndex: true)
    static let nikkei = MarketSymbol(market: .jp, code: "N225", exchange: nil, isIndex: true)
    static let sp500 = MarketSymbol(market: .us, code: "SPX", exchange: nil, isIndex: true)
    static let nasdaq = MarketSymbol(market: .us, code: "NDX", exchange: nil, isIndex: true)
    static let dow = MarketSymbol(market: .us, code: "DJI", exchange: nil, isIndex: true)

    private static let indexAliases: [String: MarketSymbol] = [
        "TAIEX": .taiex, "^TWII": .taiex, "TWSE-T00": .taiex, "TW-T00": .taiex,
        "N225": .nikkei, "^N225": .nikkei, "NIKKEI": .nikkei, "JP-N225": .nikkei,
        "SPX": .sp500, "^GSPC": .sp500, "US-SPX": .sp500,
        "NDX": .nasdaq, "^IXIC": .nasdaq, "US-NDX": .nasdaq,
        "DJI": .dow, "^DJI": .dow, "US-DJI": .dow
    ]

    // MARK: - Parsing

    /// Parses any of the accepted spellings. Returns nil for anything that isn't
    /// a recognisable instrument, which is what lets the plan and holdings
    /// loaders report an unusable id rather than silently never watching it.
    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !s.isEmpty else { return nil }

        if let index = Self.indexAliases[s] {
            self = index
            return
        }

        // Explicit `MARKET-CODE` prefixes. Checked before the suffix forms so a
        // spelling that carries both can't be read two ways.
        if let dash = s.firstIndex(of: "-") {
            let prefix = String(s[s.startIndex..<dash])
            let rest = String(s[s.index(after: dash)...])
            guard !rest.isEmpty else { return nil }
            switch prefix {
            case "TWSE", "TPEX":
                guard Self.isTWCode(rest),
                      let ex = TWExchange(rawValue: prefix.lowercased()) else { return nil }
                self.init(market: .tw, code: rest, exchange: ex, isIndex: false)
                return
            case "TSE", "JP", "JPX":
                guard Self.isJPCode(rest) else { return nil }
                self.init(market: .jp, code: rest, exchange: nil, isIndex: false)
                return
            case "US", "NYSE", "NASDAQ":
                guard Self.isUSTicker(rest) else { return nil }
                self.init(market: .us, code: rest, exchange: nil, isIndex: false)
                return
            default:
                // `BRK-B` is a real US spelling of a class share. Anything else
                // with a dash is not something we can route.
                guard Self.isClassShare(prefix, rest) else { return nil }
                self.init(market: .us, code: "\(prefix).\(rest)", exchange: nil, isIndex: false)
                return
            }
        }

        // Suffix forms — the Yahoo spellings.
        if let dot = s.lastIndex(of: ".") {
            let head = String(s[s.startIndex..<dot])
            let tail = String(s[s.index(after: dot)...])
            switch tail {
            case "TW" where Self.isTWCode(head):
                self.init(market: .tw, code: head, exchange: .twse, isIndex: false)
                return
            case "TWO" where Self.isTWCode(head):
                self.init(market: .tw, code: head, exchange: .tpex, isIndex: false)
                return
            case "T" where Self.isJPCode(head):
                self.init(market: .jp, code: head, exchange: nil, isIndex: false)
                return
            default:
                // `BRK.B` — a US class share, kept whole.
                guard Self.isClassShare(head, tail) else { return nil }
                self.init(market: .us, code: s, exchange: nil, isIndex: false)
                return
            }
        }

        // Bare. Digits are Taiwan (see the type's note on why not Japan);
        // letters are a US ticker.
        if Self.isTWCode(s) {
            self.init(market: .tw, code: s, exchange: .twse, isIndex: false)
            return
        }
        guard Self.isUSTicker(s) else { return nil }
        self.init(market: .us, code: s, exchange: nil, isIndex: false)
    }

    private init(market: Market, code: String, exchange: TWExchange?, isIndex: Bool) {
        self.market = market
        self.code = code
        self.exchange = exchange
        self.isIndex = isIndex
    }

    /// Taiwan listing codes are 4–6 digits (4 for ordinary shares, longer for
    /// warrants and ETFs). Requiring all-digits is what keeps `AAPL` out.
    private static func isTWCode(_ s: String) -> Bool {
        (4...6).contains(s.count) && s.allSatisfy(\.isNumber)
    }

    /// Japanese codes are four characters. Historically all digits, but the JPX
    /// alphanumeric scheme introduced in 2024 puts a letter in the fourth
    /// position (`130A`), so digits alone would reject the newest listings.
    private static func isJPCode(_ s: String) -> Bool {
        s.count == 4 && s.allSatisfy { $0.isNumber || $0.isLetter }
            && s.contains(where: \.isNumber)
    }

    /// 1–5 letters. Deliberately excludes digits, which is the whole basis for
    /// telling a bare US ticker from a bare Taiwan code.
    private static func isUSTicker(_ s: String) -> Bool {
        (1...5).contains(s.count) && s.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// `BRK.B`, `BF.B` — a US class share, whose suffix is always a single
    /// letter. Requiring exactly one keeps the rule tight: without it any
    /// `LETTERS.LETTERS` string parses as a US ticker, so a typo'd suffix would
    /// be silently priced in dollars rather than reported as unreadable.
    ///
    /// The known cost is that a single-letter *exchange* suffix from a market
    /// this glance doesn't support — London's `.L`, say — is indistinguishable
    /// from a class share by shape alone, and reads as US. Yahoo still resolves
    /// it, so the price is right; only the currency label and the up/down
    /// colour would follow the wrong convention. Adding that market is the fix,
    /// not a longer list of exceptions here.
    private static func isClassShare(_ head: String, _ tail: String) -> Bool {
        isUSTicker(head) && tail.count == 1 && tail.allSatisfy { $0.isLetter && $0.isASCII }
    }

    // MARK: - Spellings

    /// The canonical form we store and display, e.g. `TWSE-2330`, `TSE-7203`,
    /// `AAPL`.
    var canonical: String {
        if isIndex {
            switch self {
            case .taiex: return "TAIEX"
            default: return code
            }
        }
        switch market {
        case .tw: return "\(exchange?.rawValue.uppercased() ?? "TWSE")-\(code)"
        case .jp: return "TSE-\(code)"
        case .us: return code
        }
    }

    /// The `ex_ch` token Taiwan's MIS feed expects, e.g. `tse_2330.tw`.
    /// Nil for anything MIS has never heard of.
    var misKey: String? {
        guard market == .tw, let exchange else { return nil }
        return "\(exchange.misPrefix)_\(code).tw"
    }

    /// The spelling Yahoo's chart endpoint wants.
    var yahooSymbol: String {
        if isIndex {
            switch self {
            case .taiex: return "^TWII"
            case .nikkei: return "^N225"
            case .sp500: return "^GSPC"
            case .nasdaq: return "^IXIC"
            case .dow: return "^DJI"
            default: return code
            }
        }
        switch market {
        case .tw: return "\(code).\(exchange == .tpex ? "TWO" : "TW")"
        case .jp: return "\(code).T"
        case .us: return code
        }
    }
}
