import SwiftUI
import Observation

/// Flagship glance: a stock watchlist, and the front end for a daily Taiwan
/// trading plan.
///
/// - Data sources: Taiwan symbols go to `TWSEQuoteProvider` (the exchange's own
///   MIS feed); everything else keeps using `YahooQuoteProvider`, or
///   `FinnhubQuoteProvider` when a key is present in `CredentialStore`. Routing
///   is per symbol, so one watchlist can hold `TWSE-2330` and `AAPL`.
/// - Strategy: `StrategyPlanSource` watches a plan file on disk;
///   `StrategyEngine` evaluates it against each tick and pushes a notification
///   when a level is reached.
/// - Popover: per-symbol rows, plus a plan section showing how far the price is
///   from each level.
///
/// This is the reference implementation cited in `Core/PLUGIN_CONTRACT.md`.
@MainActor
@Observable
final class StocksPlugin: GlancePlugin {
    nonisolated var id: String { "stocks" }
    nonisolated var title: String { "Stocks" }
    nonisolated var iconSystemName: String { "chart.line.uptrend.xyaxis" }

    /// 5s — the floor MIS declares for itself via `userDelay: 5000`, and the
    /// fastest cadence the documented budget allows without eating into it.
    /// The whole watchlist rides one pipe-joined request, so this spends 1 of
    /// the 3 requests per 5-second window however many symbols are listed,
    /// leaving the history sweep room to share the same gate.
    ///
    /// Polling at the floor does *not* mean a new price every tick: the
    /// exchange's snapshot can sit unchanged for 25s at a stretch (measured
    /// 2026-07-20 — eight polls spanning `t` 09:24:00 → 09:24:25). That is why
    /// `appendSeries` is keyed on the snapshot advancing rather than on the
    /// fetch succeeding; without that the sparkline fills with repeats.
    ///
    /// A fixed, short cadence — deliberately *not* computed from market hours.
    /// `RefreshCoordinator` reads this once when it builds the loop
    /// (`Core/RefreshCoordinator.swift`), so a value that varies with the clock
    /// is frozen at whatever it was at launch. The real cadence is enforced
    /// inside `refresh()`, which is also where it belongs: that's where the
    /// rate-limit budget is spent.
    var refreshInterval: TimeInterval { 5 }

    /// Room for the two-pane plan board (a stock list beside its detail panel).
    ///
    /// 520 rather than the ~460 the two-pane strictly needs: the tool window
    /// spends 32pt on padding, and `ViewThatFits` silently drops to the narrow
    /// single-column shape the moment the remainder dips under its floor — a
    /// failure with no error and no visual clue that anything was chosen. The
    /// extra width buys margin against that.
    ///
    /// Still under Notes' 660pt, and the Quick Switch window sizes itself to the
    /// widest tool in the ring — so this gives Stocks a real detail view without
    /// making every other glance's Quick Switch window bigger.
    var preferredToolWindowSize: CGSize? { CGSize(width: 520, height: 640) }

    /// Which plan stock the detail panel is showing. Lives on the plugin rather
    /// than in `@State` so the selection survives moving between the popover,
    /// the tool window and Quick Switch — all three render the same section, and
    /// having it reset on each switch would be its own small annoyance.
    var selectedPlanStockID: String?

    /// Persisted watchlist.
    var symbols: [String] {
        didSet { UserDefaults.standard.set(symbols, forKey: watchlistKey) }
    }
    private let watchlistKey = "glancekit.stocks.watchlist"

    private(set) var quotes: [StockQuote] = []
    private(set) var lastError: String?
    private(set) var lastTaiwanFetch: Date?

    let planSource = StrategyPlanSource()
    let holdingsSource = HoldingsSource()
    let engine = StrategyEngine()

    /// Intraday prices accumulated tick by tick, so Taiwan rows get a sparkline
    /// even though MIS only ever reports a single point.
    private var seriesBuffer: [String: [Double]] = [:]
    /// One point per distinct exchange snapshot, so the cap counts *ticks* and
    /// no longer has to be retuned whenever `refreshInterval` changes. A quiet
    /// stock spends them slowly and keeps hours of context; an active one
    /// spends them fast and shows a tighter, more detailed window — which is
    /// the right bias for a sparkline either way. 720 covers a full 4.5-hour
    /// session at one snapshot every ~20s.
    private static let seriesCap = 720

    private var lastForeignFetch: Date?
    private var lastHistorySweepDay: String?
    private var lastHistoryCloseSweepDay: String?

    init() {
        // Before the app finishes launching, which is when the notification
        // centre requires its delegate. Plugins are constructed during app
        // init, so this is the earliest hook available to one.
        NotificationService.prepare()
        symbols = UserDefaults.standard.stringArray(forKey: watchlistKey)
            ?? ["TWSE-2330", "AAPL", "MSFT"]
        planSource.onChange = { [weak self] in
            // A newly loaded plan must not be judged against prices remembered
            // from the previous one.
            self?.engine.reseed()
        }
        planSource.start()
        holdingsSource.onChange = { [weak self] in
            // Share counts are derived from the portfolio, so a fresh export
            // must re-derive them on the next tick rather than at the next trade.
            guard let self else { return }
            self.engine.holdings = self.holdingsSource.holdings
        }
        holdingsSource.start()
        engine.holdings = holdingsSource.holdings
    }

    // MARK: GlancePlugin

    func refresh() async {
        var errors: [String] = []
        await refreshTaiwan(collecting: &errors)
        await refreshForeign(collecting: &errors)

        // Preserve watchlist order, then append plan-only symbols (which the
        // user never typed into the watchlist but is actively tracking).
        let ordered = symbols + planOnlySymbols()
        var seen = Set<String>()
        quotes = ordered.compactMap { key in
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return latest[key]
        }

        lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
        await runStrategy()
        await sweepHistoryIfDue()
    }

    /// Most recent quote per watchlist key, across both providers.
    private var latest: [String: StockQuote] = [:]

    // MARK: Fetching

    /// Every Taiwan symbol we need quoted: the watchlist's, the plan's, and the
    /// index when the plan has a market gate. All of them ride in one request.
    private func taiwanKeys() -> [String] {
        var keys: [String] = symbols.filter { TWSymbol($0) != nil }
        for stock in planSource.plan?.plans ?? [] where TWSymbol(stock.stockId) != nil {
            keys.append(stock.stockId)
        }
        // Everything held, not just everything planned — a position with no
        // plan still has a price, and its P/L is half the reason to look here.
        for position in holdingsSource.holdings?.positions ?? [] where TWSymbol(position.stockId) != nil {
            keys.append(position.stockId)
        }
        // Any gate at all — `line` or a `ladder` — means the index must be quoted.
        if planSource.plan?.market?.gate?.rungs.isEmpty == false { keys.append("TAIEX") }

        var seen = Set<TWSymbol>()
        return keys.filter { key in
            guard let symbol = TWSymbol(key), !seen.contains(symbol) else { return false }
            seen.insert(symbol)
            return true
        }
    }

    private func refreshTaiwan(collecting errors: inout [String]) async {
        let keys = taiwanKeys()
        guard !keys.isEmpty else { return }
        guard shouldFetchTaiwan() else { return }

        do {
            let fetched = try await TWSEQuoteProvider().fetchQuotes(keys)
            lastTaiwanFetch = Date()
            for var quote in fetched {
                // Read before `latest` is overwritten at the end of the loop.
                let priorSnapshot = latest[quote.symbol]?.quotedAt
                carryForwardLastTrade(into: &quote)
                // One point per *exchange* snapshot, not per fetch. At the 5s
                // cadence a repeated snapshot is the common case, and appending
                // it would pad the sparkline with flat runs that read as the
                // price standing still when it is only the feed that is.
                // Sources without an exchange timestamp fall back to appending.
                if quote.quotedAt == nil || quote.quotedAt != priorSnapshot {
                    appendSeries(quote.price, for: quote.symbol)
                }
                quote.series = seriesBuffer[quote.symbol] ?? []
                latest[quote.symbol] = quote
            }
            if fetched.isEmpty { errors.append("台股無回傳資料") }
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    /// The rate-limit decision, in one place. During the session we poll on the
    /// glance's cadence; outside it we drop to a token refresh every 15 minutes
    /// so the popover still shows the last close without spending a budget
    /// nobody is watching. One request covers every symbol either way.
    private func shouldFetchTaiwan(now: Date = Date()) -> Bool {
        guard let last = lastTaiwanFetch else { return true }
        let elapsed = now.timeIntervalSince(last)
        return TWMarketClock.isOpen(now) ? elapsed >= 4.5 : elapsed >= 900
    }

    private func refreshForeign(collecting errors: inout [String]) async {
        let foreign = symbols.filter { TWSymbol($0) == nil }
        guard !foreign.isEmpty else { return }

        // The 20s loop exists for Taiwan; US names don't need it and Yahoo
        // shouldn't be asked that often either.
        if let last = lastForeignFetch,
           Date().timeIntervalSince(last) < (usMarketProbablyOpen ? 60 : 900) { return }

        let provider: QuoteProvider
        if let key = CredentialStore.get("finnhub.apiKey"), !key.isEmpty {
            provider = FinnhubQuoteProvider(apiKey: key)
        } else {
            provider = YahooQuoteProvider()
        }
        do {
            let fetched = try await provider.fetchQuotes(foreign)
            lastForeignFetch = Date()
            for quote in fetched { latest[quote.symbol] = quote }
            if fetched.isEmpty { errors.append("No data returned") }
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    /// Holds the last real matched price across the snapshots where MIS reports
    /// none, so a stock that simply didn't trade in the last five seconds keeps
    /// showing what it last traded at rather than dropping to an order-book
    /// stand-in. This is the behaviour the exchange's own front end has, by
    /// virtue of leaving the previously rendered number in the DOM.
    ///
    /// Guarded on `previousClose` rather than a stored date: it is the
    /// exchange's own per-session constant, so an unchanged value means the
    /// remembered trade belongs to the session being quoted. When it changes,
    /// yesterday's last print is correctly abandoned — which matters because
    /// `latest` outlives a session whenever the app is left running overnight.
    private func carryForwardLastTrade(into quote: inout StockQuote) {
        guard quote.tradePrice == nil,
              let prior = latest[quote.symbol],
              let priorTrade = prior.tradePrice,
              prior.previousClose == quote.previousClose else { return }
        quote.price = priorTrade
        quote.tradePrice = priorTrade
    }

    private func appendSeries(_ price: Double, for key: String) {
        var buffer = seriesBuffer[key] ?? []
        buffer.append(price)
        if buffer.count > Self.seriesCap { buffer.removeFirst(buffer.count - Self.seriesCap) }
        seriesBuffer[key] = buffer
    }

    private func planOnlySymbols() -> [String] {
        let known = Set(symbols)
        return (planSource.plan?.plans ?? [])
            .map(\.stockId)
            .filter { !known.contains($0) && TWSymbol($0) != nil }
    }

    // MARK: Strategy

    private func runStrategy() async {
        guard let plan = planSource.plan else { return }
        // Reviewing a past day's plan must not fire today's notifications off
        // its levels. `activatePinned()` is the deliberate way to arm one.
        guard !planSource.isPinned else { return }
        var bySymbol: [TWSymbol: StockQuote] = [:]
        for (key, quote) in latest {
            if let symbol = TWSymbol(key) { bySymbol[symbol] = quote }
        }
        guard !bySymbol.isEmpty else { return }

        let alerts = await engine.evaluate(plan: plan, quotes: bySymbol)
        for alert in alerts {
            // Exits red, entries green — the colour is the first thing read.
            let tint: Color = alert.isApproach ? .orange
                : (StocksFormat.tint(for: alert.levelKind))
            NotificationService.post(title: alert.title, body: alert.body, tint: tint,
                             identifier: alert.id, source: "stocks")
        }
    }

    /// Daily bars, once per trading day after the close. Separate from the
    /// realtime path in every way except the shared rate gate — which is the
    /// whole point of the gate.
    /// Daily bars, twice a day at most.
    ///
    /// The morning sweep is the one that matters and used to be missing: a plan
    /// that expresses volume relatively (`{"multiple": 1.5, "refAvgDays": 20}`
    /// rather than a hard 2602 張) can't be evaluated at all without the 20-day
    /// average, and an unmeasurable condition is treated as unmet — so waiting
    /// until 14:00 to fetch history meant those entries could never fire during
    /// the session they were written for. Yesterday's bars are all the average
    /// needs and they're available at any hour.
    ///
    /// The post-close sweep then picks up today's own bar, which is what the
    /// multi-session rules (`破X後3日內收回`) walk.
    private func sweepHistoryIfDue() async {
        guard planSource.plan != nil else { return }
        let today = TWMarketClock.tradingDay()
        let needsMorning = lastHistorySweepDay != today
        let needsPostClose = TWMarketClock.isAfterClose() && lastHistoryCloseSweepDay != today
        guard needsMorning || needsPostClose else { return }

        lastHistorySweepDay = today
        if TWMarketClock.isAfterClose() { lastHistoryCloseSweepDay = today }

        let symbols = taiwanKeys().compactMap { TWSymbol($0) }
        await TWSEHistoryStore.shared.refresh(symbols: symbols, force: needsPostClose)
    }

    // MARK: Signal

    /// With a plan loaded, the plan is the news: a level that fired today, or
    /// one the price is sitting right on top of, is what deserves the card. The
    /// old biggest-mover behaviour stays as the fallback for a watchlist with no
    /// plan attached, and its high thresholds still apply — markets wiggle a
    /// percent or two constantly, and treating that as news lets the stock card
    /// claim the feed on almost every open.
    func currentSignal() -> GlanceSignal? {
        if let signal = planSignal() { return signal }
        return moverSignal()
    }

    private func planSignal() -> GlanceSignal? {
        guard planSource.plan != nil else { return nil }

        // A real trigger outranks any approach warning, however recent — being
        // 2% from the stop is not news next to having hit it. So the feed shows
        // the latest genuine trigger if there is one, and only falls back to the
        // latest heads-up otherwise.
        if let alert = engine.recentAlerts.first(where: { !$0.isApproach }) ?? engine.recentAlerts.first {
            let exiting = alert.levelKind == "cut" || alert.levelKind == "trim"
            return GlanceSignal(
                priority: alert.isApproach ? .elevated : .urgent,
                score: alert.isApproach ? 20 : 100,
                headline: alert.title,
                detail: alert.body.split(separator: "\n").first.map(String.init),
                systemImage: alert.isApproach ? "bell" : "bell.badge.fill",
                tint: alert.isApproach ? .orange : (exiting ? .red : .green),
                accessory: .none)
        }

        // Nothing has fired — surface the level the price is closest to, but
        // only once it's within a percent. Further away it isn't yet a decision.
        var nearest: (stock: String, status: LevelStatus, distance: Double)?
        for (stockId, rows) in engine.statuses {
            for row in rows where !row.isAdvisoryOnly && !row.hasFired {
                guard let distance = row.distancePercent.map(abs) else { continue }
                if nearest == nil || distance < nearest!.distance {
                    let name = planSource.plan?.plans.first { $0.stockId == stockId }?.displayName ?? stockId
                    nearest = (name, row, distance)
                }
            }
        }
        guard let nearest, nearest.distance <= 1.0, let line = nearest.status.line else { return nil }
        return GlanceSignal(
            priority: .elevated, score: 10 - nearest.distance,
            headline: String(format: "%@ 逼近%@ %@（%.2f%%）",
                             nearest.stock, StocksFormat.levelLabel(nearest.status.kind),
                             StocksFormat.price(line), nearest.distance),
            detail: nearest.status.condition,
            systemImage: iconSystemName,
            tint: .orange,
            accessory: .none)
    }

    private func moverSignal() -> GlanceSignal? {
        guard let mover = quotes.max(by: { abs($0.changePercent) < abs($1.changePercent) }) else {
            return nil
        }
        let magnitude = abs(mover.changePercent)
        let open = TWSymbol(mover.symbol) != nil ? TWMarketClock.isOpen() : usMarketProbablyOpen
        // Below this, a stock has nothing time-sensitive to say — stay out of the
        // feed rather than filling it with routine noise. The threshold is higher
        // after the close, where a stale flat quote is even less worth a card.
        let floor: Double = open ? 3 : 5
        if magnitude < floor { return nil }

        let headline = String(format: "%@ %@%.2f%% · %.2f",
                              mover.name ?? mover.symbol, mover.isUp ? "+" : "−", magnitude, mover.price)
        let tint: Color = mover.isUp ? .green : .red
        // Only a genuinely outsized move (≥8%) earns the elevated rank that leads
        // the brief; a merely notable one sits at normal, below anything urgent.
        let priority: GlanceSignal.Priority = magnitude >= 8 ? .elevated : .normal
        return GlanceSignal(priority: priority, score: magnitude,
                            headline: headline,
                            detail: open ? nil : "At last close",
                            systemImage: iconSystemName, tint: tint,
                            accessory: mover.series.count > 1 ? .sparkline(mover.series, up: mover.isUp) : .none)
    }

    func popoverSection() -> AnyView {
        AnyView(StocksPopover(plugin: self))
    }

    func settingsSection() -> AnyView {
        AnyView(StocksSettings(plugin: self))
    }

    // MARK: Helpers

    /// Live quotes keyed by watchlist spelling, for the plan board.
    var quotesByKey: [String: StockQuote] { latest }

    /// Rough US-market-hours heuristic (weekday, 9:30–16:00 ET) used only to
    /// pick a refresh cadence — not for correctness.
    private var usMarketProbablyOpen: Bool {
        var cal = Calendar(identifier: .gregorian)
        guard let et = TimeZone(identifier: "America/New_York") else { return true }
        cal.timeZone = et
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: Date())
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else { return true }
        if weekday == 1 || weekday == 7 { return false } // Sun/Sat
        let minutes = hour * 60 + minute
        return minutes >= (9 * 60 + 30) && minutes <= (16 * 60)
    }
}

// MARK: - Popover UI

/// The glance's single rendering surface, shown in the 240pt menu column, the
/// standalone tool window, and Quick Switch alike. The plan board inside it
/// picks its own shape via `ViewThatFits` — see `StocksViews.swift`.
private struct StocksPopover: View {
    @Bindable var plugin: StocksPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let planError = plugin.planSource.error {
                Label(planError, systemImage: "doc.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plugin.quotes.isEmpty {
                Text("No quotes yet\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plugin.quotes) { quote in
                        StocksQuoteRow(quote: quote)
                    }
                }
            }

            // Below the rows rather than above: it's a reassurance to glance
            // down at, not something to read before the prices.
            StocksFeedStatus(lastFetch: plugin.lastTaiwanFetch)

            Divider()

            StocksHoldingsSection(
                source: plugin.holdingsSource,
                quotes: plugin.quotesByKey,
                plannedIDs: Set(plugin.planSource.plan?.plans.map(\.stockId) ?? []))

            Divider()

            // Always shown, even with no plan loaded: the import control lives
            // here, so a plan has to be reachable from the glance itself.
            StocksPlanBoard(source: plugin.planSource,
                            engine: plugin.engine,
                            quotes: plugin.quotesByKey,
                            selection: $plugin.selectedPlanStockID)
        }
    }
}


// MARK: - Settings UI

private struct StocksSettings: View {
    @Bindable var plugin: StocksPlugin
    @State private var symbolsText: String = ""
    @State private var finnhubKey: String = ""
    @State private var approachText: String = ""
    @State private var savedNote: String?


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watchlist")
                .font(.headline)
            Text("Comma-separated symbols. Taiwan: TWSE-2330 / TPEX-3491 / 2330.TW. Everything else goes to Yahoo or Finnhub.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("TWSE-2330, AAPL, MSFT", text: $symbolsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Save watchlist") {
                plugin.symbols = symbolsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
                Task { await plugin.refresh() }
            }

            Divider()

            Text("交易計畫")
                .font(.headline)
            Text("選一個 JSON 檔，存檔後自動重新載入。價格觸及計畫中的關卡時發送通知。格式見 PLAN_SCHEMA.md。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("選擇計畫檔…") { plugin.planSource.chooseFile() }
                if plugin.planSource.displayPath != nil {
                    Button("移除") { plugin.planSource.clear() }
                    Button("重新載入") {
                        plugin.planSource.reload()
                        Task { await plugin.refresh() }
                    }
                }
            }
            if let path = plugin.planSource.displayPath {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let plan = plugin.planSource.plan {
                Text("已載入 \(plan.date ?? "?")，\(plan.plans.count) 檔")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error = plugin.planSource.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("接近提醒")
                .font(.headline)
            Text("價格接近關卡到這些百分比時，先發一則提醒。以逗號分隔，留空即關閉。每個關卡每個級距每天只提醒一次。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("10, 5, 2", text: $approachText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("儲存") {
                    plugin.engine.setApproachBands(
                        approachText.split(whereSeparator: { ",，、 ".contains($0) })
                            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) })
                    approachText = plugin.engine.approachBands
                        .map { String(format: "%g", $0) }.joined(separator: ", ")
                }
            }

            Divider()

            // Notification behaviour (panel, sound, system notification,
            // permissions) lives in Settings → Notifications, since it is
            // app-wide rather than a property of this glance.
            Text("Notification appearance is configured in the Notifications page.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Finnhub API key (optional)")
                .font(.headline)
            Text("Provide a key for more reliable US quotes. Stored in Glancekit's credentials file, not in app preferences. Leave blank to use the keyless Yahoo source. Taiwan quotes need no key.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("Finnhub API key", text: $finnhubKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save key") {
                    CredentialStore.set(finnhubKey.isEmpty ? nil : finnhubKey, for: "finnhub.apiKey")
                    savedNote = "Saved."
                    Task { await plugin.refresh() }
                }
                if let note = savedNote {
                    Text(note).font(.caption).foregroundStyle(.green)
                }
            }
        }
        .onAppear {
            symbolsText = plugin.symbols.joined(separator: ", ")
            finnhubKey = CredentialStore.get("finnhub.apiKey") ?? ""
            approachText = plugin.engine.approachBands
                .map { String(format: "%g", $0) }.joined(separator: ", ")
        }
    }
}
