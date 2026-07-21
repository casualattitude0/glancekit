import SwiftUI

/// A market this glance can quote, and the one place that knows what differs
/// between them.
///
/// Everything that is a *property of the market* rather than of a symbol lives
/// here: the trading calendar, the currency, the unit volume is reported in,
/// and — the one that surprises people — which direction is red.
///
/// The alternative was scattering `if isTaiwan` through the views, which is how
/// a glance ends up showing a Tokyo price with a New York colour.
enum Market: String, Codable, CaseIterable, Sendable {
    case tw
    case us
    case jp

    var displayName: String {
        switch self {
        case .tw: return "Taiwan"
        case .us: return "United States"
        case .jp: return "Japan"
        }
    }

    /// The two-letter tag shown on a row when a watchlist spans markets.
    var badge: String { rawValue.uppercased() }

    // MARK: - Money

    var currencyCode: String {
        switch self {
        case .tw: return "TWD"
        case .us: return "USD"
        case .jp: return "JPY"
        }
    }

    var currencySymbol: String {
        switch self {
        case .tw: return "NT$"
        case .us: return "$"
        case .jp: return "¥"
        }
    }

    /// Decimals a *price* is quoted to. Taiwan and Japan trade on coarse tick
    /// grids where most prices are whole numbers, so their trailing zeros are
    /// dropped by `StocksFormat.price`; US names are quoted in cents and a bare
    /// "227.5" reads as a truncation rather than a price.
    var priceDecimals: Int {
        switch self {
        case .tw: return 2
        case .us: return 2
        case .jp: return 1
        }
    }

    /// Whether a whole-number price should print without decimals. US quotes
    /// keep them (`227.00`), the coarse-grid markets drop them (`1355`).
    var trimsWholePrices: Bool { self != .us }

    // MARK: - Colour convention
    //
    // East Asian markets print rises in red and falls in green; Western markets
    // do the reverse. This is not a preference to be normalized away — someone
    // reading a Taipei board and this panel side by side needs them to agree,
    // and a green 台積電 up-tick reads as a loss at a glance.

    /// True where a rising price is drawn in red (Taiwan, Japan).
    var risingIsRed: Bool { self != .us }

    /// The colour for a price move in this market's own convention.
    func tint(rising: Bool) -> Color {
        if risingIsRed { return rising ? .red : .green }
        return rising ? .green : .red
    }

    /// The arrow drawn beside a move. Identical in every market — it is the cue
    /// that survives when the colours flip, and for anyone who can't separate
    /// the two hues it is the *only* cue.
    static func arrow(rising: Bool) -> String { rising ? "▲" : "▼" }

    // MARK: - Volume

    /// What the exchange reports accumulated volume in.
    ///
    /// Taiwan publishes 張 (lots of 1,000 shares) and every strategy-plan volume
    /// condition is written in that unit, so no conversion happens anywhere
    /// between the feed and the rule. Yahoo reports US and Japanese volume in
    /// shares.
    enum VolumeUnit { case lots, shares }

    var volumeUnit: VolumeUnit { self == .tw ? .lots : .shares }

    // MARK: - Trading calendar
    //
    // Deliberately does *not* model market holidays, for any of the three:
    // there is no free, stable feed for them, and getting one wrong would
    // silently stop alerts on a real trading day — the expensive failure.
    // Treating a holiday as open is the cheap failure instead: the feed returns
    // the previous session's stale data, no level crosses, and nothing fires.
    // The cost is a handful of wasted requests on ~15 days a year, which the
    // rate gate absorbs without noticing.

    var timeZone: TimeZone {
        switch self {
        case .tw: return TimeZone(identifier: "Asia/Taipei") ?? .gmt
        case .us: return TimeZone(identifier: "America/New_York") ?? .gmt
        case .jp: return TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        }
    }

    /// Continuous trading sessions, as minutes since local midnight. Tokyo is
    /// the reason this is a list rather than a pair: it breaks for lunch, and a
    /// single 09:00–15:30 window would report the exchange as open through it.
    ///
    /// Tokyo's 15:30 close is the post-2024 one — TSE extended the afternoon
    /// session by thirty minutes on 2024-11-05.
    var sessions: [(open: Int, close: Int)] {
        switch self {
        case .tw: return [(9 * 60, 13 * 60 + 30)]
        case .us: return [(9 * 60 + 30, 16 * 60)]
        case .jp: return [(9 * 60, 11 * 60 + 30), (12 * 60 + 30, 15 * 60 + 30)]
        }
    }

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal
    }

    /// Minutes since local midnight, or nil if the date can't be decomposed.
    private func minutes(_ date: Date) -> Int? {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        guard let h = c.hour, let m = c.minute else { return nil }
        return h * 60 + m
    }

    private func isWeekday(_ date: Date) -> Bool {
        let wd = calendar.component(.weekday, from: date)
        return wd != 1 && wd != 7
    }

    /// Inside any continuous session — the window we're willing to spend
    /// requests in.
    func isOpen(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return sessions.contains { m >= $0.open && m <= $0.close }
    }

    private var closingMinute: Int { sessions.last?.close ?? 0 }

    /// The last five minutes of the final session, when the running price is a
    /// good enough proxy for the close that an on-close condition can be
    /// provisionally evaluated. The engine still re-confirms once after the bell.
    func isCloseWindow(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return m >= closingMinute - 5 && m <= closingMinute
    }

    /// True once the session has ended for the day (and it was a weekday) — the
    /// window in which an on-close condition can be settled and daily history is
    /// worth fetching. Half an hour past the bell rather than on it, so the
    /// exchange has published.
    func isAfterClose(_ now: Date = Date()) -> Bool {
        guard isWeekday(now), let m = minutes(now) else { return false }
        return m >= closingMinute + 30
    }

    /// `yyyy-MM-dd` in the market's own zone — the key everything per-day is
    /// bucketed under (alert dedupe, once-a-day history fetches).
    func tradingDay(_ now: Date = Date()) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `HH:mm` in the market's own zone. A Taipei fill stamped in New York time
    /// is a number you have to do arithmetic on before you can use it.
    func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = timeZone
        return f.string(from: date)
    }

    // MARK: - Polling

    /// How often to refetch while the market is open.
    ///
    /// Taiwan rides its exchange's own MIS feed, which declares a 5-second floor
    /// for itself and serves the whole watchlist in one pipe-joined request —
    /// so polling at the floor costs one request per tick however many symbols
    /// are listed. US and Japanese quotes come from Yahoo, one request per
    /// symbol, on an endpoint nobody promised us; a minute is plenty for a
    /// menu-bar glance and stays well clear of being rate-limited.
    var openCadence: TimeInterval { self == .tw ? 5 : 60 }

    /// How often to refetch outside the session — a token refresh, so the panel
    /// still shows the last close without spending a budget nobody is watching.
    var closedCadence: TimeInterval { 900 }

    func cadence(_ now: Date = Date()) -> TimeInterval {
        isOpen(now) ? openCadence : closedCadence
    }
}
