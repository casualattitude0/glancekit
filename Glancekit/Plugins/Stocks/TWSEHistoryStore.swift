import Foundation

/// One session's daily bar, normalized across the two exchanges.
struct TWDailyBar: Codable, Equatable {
    /// `yyyy-MM-dd`, Gregorian (the sources publish ROC years; converted here).
    let date: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    /// Volume in 張 (lots) — TWSE publishes 成交股數 (shares) and TPEX publishes
    /// 成交張數 (lots), so TWSE is divided by 1000 to make them comparable.
    /// Every volume condition in a strategy plan is written in 張.
    let volumeLots: Double
}

/// Daily bars for **Taiwan** symbols, from the same after-hours endpoints
/// `mlouielu/twstock` uses.
///
/// Taiwan-only on purpose. The two endpoints below are TWSE's and TPEX's own,
/// and the plan features that need daily bars — moving averages, relative
/// volume, the multi-session reclaim rules — are all written against a Taiwan
/// trading plan. A US or Japanese symbol asked for a moving average here gets
/// nil, which the engine already treats as "cannot be measured" and the level
/// row surfaces as `Awaiting daily bars` rather than pretending to be armed.
///
/// This exists because the realtime feed only knows about *today*, and a
/// strategy plan is full of statements that aren't about today:
/// - moving averages (`MA20=1297.75`) that drift every session, so a plan more
///   than a day old is quoting numbers that have since moved;
/// - relative-volume conditions (量縮 / 帶量) that need a 20-day baseline;
/// - the multi-session rules (`破1195後3日內帶量收回`) that are simply
///   unevaluable from a single snapshot.
///
/// The cost is kept negligible by shape rather than by throttling alone: a past
/// month's bars can never change, so once cached they are never refetched. In
/// steady state this is one request per symbol per day, after the close, and it
/// shares `TWRateGate` with realtime polling so the two can't stack.
actor TWSEHistoryStore {
    static let shared = TWSEHistoryStore()

    /// Enough calendar months to always cover a 60-session moving average
    /// (~3 months of sessions) with margin for a short current month.
    private static let monthsBack = 4

    private var client = NetworkClient()
    private var gate: TWRateGate = .shared

    /// In-memory bars per symbol, oldest → newest.
    private var bars: [MarketSymbol: [TWDailyBar]] = [:]
    /// Trading day of the last successful refresh, so we sweep at most once a day.
    private var lastSweepDay: [MarketSymbol: String] = [:]

    // MARK: Reads

    func bars(for symbol: MarketSymbol) -> [TWDailyBar] { bars[symbol] ?? [] }

    /// Simple moving average of the last `n` closes, or nil if we don't have
    /// `n` sessions yet. Nil is meaningful: the caller falls back to the number
    /// written in the plan rather than inventing an average from a short window.
    func movingAverage(_ n: Int, for symbol: MarketSymbol) -> Double? {
        let closes = (bars[symbol] ?? []).suffix(n).map(\.close)
        guard closes.count == n, n > 0 else { return nil }
        return closes.reduce(0, +) / Double(n)
    }

    /// Average daily volume in 張 over the last `n` sessions — the baseline a
    /// 量≥均量×1.5 condition is measured against.
    func averageVolumeLots(_ n: Int, for symbol: MarketSymbol) -> Double? {
        let vols = (bars[symbol] ?? []).suffix(n).map(\.volumeLots)
        guard vols.count == n, n > 0 else { return nil }
        return vols.reduce(0, +) / Double(n)
    }

    /// The most recent `n` bars, newest last — what the 3-day rules walk.
    func recentBars(_ n: Int, for symbol: MarketSymbol) -> [TWDailyBar] {
        Array((bars[symbol] ?? []).suffix(n))
    }

    // MARK: Refresh

    /// Ensures bars are loaded and current for these symbols. Cheap and
    /// idempotent: cached months are read from disk, and a symbol already swept
    /// today does nothing at all.
    /// `force` re-fetches the current month even if this symbol was already
    /// swept today — the post-close pass, which exists to pick up today's bar
    /// after the morning pass has already claimed the day.
    func refresh(symbols: [MarketSymbol], now: Date = Date(), force: Bool = false) async {
        let today = Market.tw.tradingDay(now)
        for symbol in symbols where symbol.market == .tw && !symbol.isIndex {
            if bars[symbol] == nil { bars[symbol] = loadFromDisk(symbol) }
            guard force || lastSweepDay[symbol] != today else { continue }
            await sweep(symbol, now: now, today: today)
        }
    }

    private func sweep(_ symbol: MarketSymbol, now: Date, today: String) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Market.tw.timeZone

        var collected: [String: TWDailyBar] = [:]
        for bar in bars[symbol] ?? [] { collected[bar.date] = bar }

        var anyFetched = false
        for offset in stride(from: Self.monthsBack - 1, through: 0, by: -1) {
            guard let monthDate = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month], from: monthDate)
            guard let year = c.year, let month = c.month else { continue }
            let isCurrentMonth = offset == 0

            // A past month is immutable once published — read it from disk and
            // never ask the exchange for it again. This is what keeps the daily
            // cost at one request per symbol instead of four.
            if !isCurrentMonth, let cached = loadMonth(symbol, year: year, month: month) {
                for bar in cached { collected[bar.date] = bar }
                continue
            }

            guard let fetched = await fetchMonth(symbol, year: year, month: month) else { continue }
            anyFetched = true
            saveMonth(fetched, symbol: symbol, year: year, month: month)
            for bar in fetched { collected[bar.date] = bar }
        }

        // Only claim the day as swept if the network actually answered;
        // otherwise a transient failure would suppress retries until tomorrow.
        if anyFetched { lastSweepDay[symbol] = today }
        bars[symbol] = collected.values.sorted { $0.date < $1.date }
    }

    private func fetchMonth(_ symbol: MarketSymbol, year: Int, month: Int) async -> [TWDailyBar]? {
        guard let exchange = symbol.exchange else { return nil }
        await gate.acquire(.history)
        switch exchange {
        case .twse:
            let url = String(format:
                "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=%04d%02d01&stockNo=%@&response=json",
                year, month, symbol.code)
            guard let data = try? await client.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["stat"] as? String == "OK",
                  let rows = json["data"] as? [[String]] else { return nil }
            // 日期, 成交股數, 成交金額, 開盤價, 最高價, 最低價, 收盤價, …
            return rows.compactMap { row in
                guard row.count >= 7, let date = gregorianDate(fromROC: row[0]) else { return nil }
                guard let shares = number(row[1]), let o = number(row[3]),
                      let h = number(row[4]), let l = number(row[5]), let c = number(row[6])
                else { return nil }
                return TWDailyBar(date: date, open: o, high: h, low: l, close: c,
                                  volumeLots: shares / 1000)
            }

        case .tpex:
            let url = String(format:
                "https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code=%@&date=%04d/%02d/01&response=json",
                symbol.code, year, month)
            guard let data = try? await client.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tables = json["tables"] as? [[String: Any]],
                  let rows = tables.first?["data"] as? [[String]] else { return nil }
            // 日期, 成交張數, 成交仟元, 開盤, 最高, 最低, 收盤, …
            // Already in 張, unlike TWSE — do not divide.
            return rows.compactMap { row in
                guard row.count >= 7, let date = gregorianDate(fromROC: row[0]) else { return nil }
                guard let lots = number(row[1]), let o = number(row[3]),
                      let h = number(row[4]), let l = number(row[5]), let c = number(row[6])
                else { return nil }
                return TWDailyBar(date: date, open: o, high: h, low: l, close: c, volumeLots: lots)
            }
        }
    }

    // MARK: Parsing helpers

    /// Both sources date rows in ROC years: `115/07/17` → `2026-07-17`.
    private func gregorianDate(fromROC s: String) -> String? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/")
        guard parts.count == 3, let roc = Int(parts[0]),
              let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return String(format: "%04d-%02d-%02d", roc + 1911, month, day)
    }

    /// Values arrive thousands-separated ("37,544,470") and occasionally as
    /// "--" on a suspended session.
    private func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces))
    }

    // MARK: Disk cache

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Glancekit/stocks-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func monthFile(_ symbol: MarketSymbol, year: Int, month: Int) -> URL {
        cacheDirectory.appendingPathComponent(
            String(format: "%@-%04d%02d.json", symbol.canonical, year, month))
    }

    private func loadMonth(_ symbol: MarketSymbol, year: Int, month: Int) -> [TWDailyBar]? {
        guard let data = try? Data(contentsOf: monthFile(symbol, year: year, month: month)) else { return nil }
        return try? JSONDecoder().decode([TWDailyBar].self, from: data)
    }

    private func saveMonth(_ bars: [TWDailyBar], symbol: MarketSymbol, year: Int, month: Int) {
        guard let data = try? JSONEncoder().encode(bars) else { return }
        try? data.write(to: monthFile(symbol, year: year, month: month), options: [.atomic])
    }

    /// Every cached month for a symbol, merged — the warm start on launch, so
    /// moving averages are available before the first network sweep.
    private func loadFromDisk(_ symbol: MarketSymbol) -> [TWDailyBar] {
        let prefix = symbol.canonical + "-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil) else { return [] }
        var merged: [String: TWDailyBar] = [:]
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            guard let data = try? Data(contentsOf: file),
                  let bars = try? JSONDecoder().decode([TWDailyBar].self, from: data) else { continue }
            for bar in bars { merged[bar.date] = bar }
        }
        return merged.values.sorted { $0.date < $1.date }
    }
}
