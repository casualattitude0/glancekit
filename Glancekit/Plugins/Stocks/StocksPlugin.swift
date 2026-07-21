import SwiftUI
import Observation

/// Flagship glance: a multi-market stock watchlist, and the front end for a
/// daily trading plan.
///
/// - Data sources: Taiwan symbols go to `TWSEQuoteProvider` (the exchange's own
///   MIS feed); US and Japanese symbols go to `YahooQuoteProvider`, with
///   `FinnhubQuoteProvider` taking over the US leg when a key is present in
///   `CredentialStore`. Routing is per symbol, so one watchlist can hold
///   `TWSE-2330`, `AAPL` and `TSE-7203` at once.
/// - Cadence is per market, from `Market.cadence`: each market polls on its own
///   clock, and one whose session has ended drops to a token refresh instead of
///   spending a budget nobody is watching.
/// - Strategy: `StrategyPlanSource` watches a plan file on disk;
///   `StrategyEngine` evaluates it against each tick and pushes a notification
///   when a level is reached.
/// - Popover: per-symbol rows, the portfolio, plus a plan section showing how
///   far the price is from each level.
///
/// This is the reference implementation cited in `Core/PLUGIN_CONTRACT.md`.
@MainActor
@Observable
final class StocksPlugin: GlancePlugin {
    nonisolated var id: String { "stocks" }
    nonisolated var title: String { "Stocks" }
    nonisolated var iconSystemName: String { "chart.line.uptrend.xyaxis" }

    /// 5s — the floor Taiwan's MIS declares for itself via `userDelay: 5000`,
    /// and the fastest cadence the documented budget allows without eating into
    /// it. The whole Taiwan watchlist rides one pipe-joined request, so this
    /// spends 1 of the 3 requests per 5-second window however many symbols are
    /// listed, leaving the history sweep room to share the same gate.
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
    /// is frozen at whatever it was at launch. The real per-market cadence is
    /// enforced inside `refresh()`, which is also where it belongs: that's where
    /// the rate-limit budget is spent.
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

    /// Which of the three sections is on screen. On the plugin for the same
    /// reason as `selectedPlanStockID`: the popover, tool window and Quick
    /// Switch all render the same view, and a tab that reset every time you
    /// moved between them would be a small daily irritation.
    var selectedSection: StocksSection = .prices

    /// Persisted watchlist.
    var symbols: [String] {
        didSet { UserDefaults.standard.set(symbols, forKey: watchlistKey) }
    }
    private let watchlistKey = "glancekit.stocks.watchlist"

    private(set) var quotes: [StockQuote] = []
    private(set) var lastError: String?

    /// When each market last answered. Per market rather than global: a Tokyo
    /// feed that has gone quiet must not be masked by New York still ticking.
    private(set) var lastFetch: [Market: Date] = [:]

    let planSource = StrategyPlanSource()
    let holdingsSource = HoldingsSource()
    let engine = StrategyEngine()

    /// Intraday prices accumulated tick by tick, so rows get a sparkline even
    /// from sources that only ever report a single point (Taiwan's MIS, Finnhub).
    private var seriesBuffer: [String: [Double]] = [:]
    /// One point per distinct exchange snapshot, so the cap counts *ticks* and
    /// no longer has to be retuned whenever `refreshInterval` changes. A quiet
    /// stock spends them slowly and keeps hours of context; an active one
    /// spends them fast and shows a tighter, more detailed window — which is
    /// the right bias for a sparkline either way. 720 covers a full 4.5-hour
    /// session at one snapshot every ~20s.
    private static let seriesCap = 720

    private var lastHistorySweepDay: String?
    private var lastHistoryCloseSweepDay: String?

    init() {
        // Before the app finishes launching, which is when the notification
        // centre requires its delegate. Plugins are constructed during app
        // init, so this is the earliest hook available to one.
        NotificationService.prepare()
        symbols = UserDefaults.standard.stringArray(forKey: watchlistKey)
            ?? ["TWSE-2330", "AAPL", "TSE-7203"]
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
        // Markets in a fixed order so an error string doesn't reshuffle itself
        // between ticks and read as new information.
        for market in Market.allCases {
            await refresh(market, collecting: &errors)
        }

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

    /// Most recent quote per watchlist key, across every provider.
    private var latest: [String: StockQuote] = [:]

    // MARK: Fetching

    /// Every symbol we need quoted, grouped by market: the watchlist's, the
    /// plan's, everything held, and the index when the plan has a market gate.
    ///
    /// Deduped on the *parsed* symbol rather than the text, so `2330`,
    /// `2330.TW` and `TWSE-2330` cost one quote between them however many of
    /// those spellings are floating around a plan and a portfolio.
    private func keysByMarket() -> [Market: [String]] {
        var keys: [String] = symbols
        for stock in planSource.plan?.plans ?? [] { keys.append(stock.stockId) }
        // Everything held, not just everything planned — a position with no
        // plan still has a price, and its P/L is half the reason to look here.
        for position in holdingsSource.holdings?.positions ?? [] { keys.append(position.stockId) }
        // Any gate at all — `line` or a `ladder` — means the index must be quoted.
        if planSource.plan?.market?.gate?.rungs.isEmpty == false { keys.append("TAIEX") }

        var seen = Set<MarketSymbol>()
        var out: [Market: [String]] = [:]
        for key in keys {
            guard let symbol = MarketSymbol(key), !seen.contains(symbol) else { continue }
            seen.insert(symbol)
            out[symbol.market, default: []].append(key)
        }
        return out
    }

    /// Which markets this glance is currently watching, in a stable order —
    /// what the feed-status rows are drawn from.
    var activeMarkets: [Market] {
        let present = Set(keysByMarket().keys)
        return Market.allCases.filter { present.contains($0) }
    }

    /// The exchange's own timestamp on the freshest quote we hold for a market.
    ///
    /// Distinct from `lastFetch`, and the gap between them is the point: Taiwan's
    /// MIS stamps its snapshots 5–6s behind its own clock and only advances them
    /// every 15–20s (measured 2026-07-20), so a quote that arrived just now can
    /// still be twenty seconds old. Surfacing this stops that showing up as an
    /// unexplained lag against a broker terminal.
    func quotedAt(for market: Market) -> Date? {
        latest.values.filter { $0.market == market }.compactMap(\.quotedAt).max()
    }

    private func refresh(_ market: Market, collecting errors: inout [String]) async {
        guard let keys = keysByMarket()[market], !keys.isEmpty else { return }
        guard shouldFetch(market) else { return }

        do {
            let fetched = try await provider(for: market).fetchQuotes(keys)
            lastFetch[market] = Date()
            for var quote in fetched {
                // Read before `latest` is overwritten at the end of the loop.
                let priorSnapshot = latest[quote.symbol]?.quotedAt
                carryForwardLastTrade(into: &quote)
                // One point per *exchange* snapshot, not per fetch. At Taiwan's
                // 5s cadence a repeated snapshot is the common case, and
                // appending it would pad the sparkline with flat runs that read
                // as the price standing still when it is only the feed that is.
                // Sources without an exchange timestamp fall back to appending.
                if quote.quotedAt == nil || quote.quotedAt != priorSnapshot {
                    appendSeries(quote.price, for: quote.symbol)
                }
                // Only fill in our own sampled series where the source gave
                // none. Yahoo returns a real 5-minute intraday curve, and
                // overwriting it with a handful of points we happened to poll
                // would be a strictly worse chart.
                if quote.series.count < 2 {
                    quote.series = seriesBuffer[quote.symbol] ?? []
                }
                latest[quote.symbol] = quote
            }
            if fetched.isEmpty { errors.append("\(market.badge): no data returned") }
        } catch {
            errors.append("\(market.badge): \(error.localizedDescription)")
        }
    }

    /// Taiwan rides its exchange's own feed; everything else goes to Yahoo,
    /// except US names once a Finnhub key exists. Finnhub's free tier doesn't
    /// cover Taipei or Tokyo, so it is never asked about them — an empty answer
    /// there would look like a dead feed rather than an unsupported market.
    private func provider(for market: Market) -> QuoteProvider {
        switch market {
        case .tw:
            return TWSEQuoteProvider()
        case .us:
            if let key = CredentialStore.get("finnhub.apiKey"), !key.isEmpty {
                return FinnhubQuoteProvider(apiKey: key)
            }
            return YahooQuoteProvider()
        case .jp:
            return YahooQuoteProvider()
        }
    }

    /// The rate-limit decision, in one place. During a session we poll on the
    /// market's own cadence; outside it we drop to a token refresh so the
    /// popover still shows the last close.
    ///
    /// The 10% slack is what stops loop jitter from skipping a tick: the refresh
    /// loop fires on a fixed 5s timer, and a strict "has a full 5s elapsed" test
    /// misses by a millisecond often enough to halve the effective cadence.
    private func shouldFetch(_ market: Market, now: Date = Date()) -> Bool {
        guard let last = lastFetch[market] else { return true }
        return now.timeIntervalSince(last) >= market.cadence(now) * 0.9
    }

    /// Holds the last real matched price across the snapshots where a feed
    /// reports none, so a stock that simply didn't trade in the last five
    /// seconds keeps showing what it last traded at rather than dropping to an
    /// order-book stand-in. This is the behaviour the Taiwan exchange's own
    /// front end has, by virtue of leaving the previously rendered number in the
    /// DOM. Sources that always quote a real trade set `tradePrice`, and never
    /// reach the body of this.
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

        // A remembered print is only worth showing while the live book still
        // agrees with it. The traded-price field can stay blank for minutes at a
        // stretch, and over that span the market can walk away from the last
        // trade entirely — at which point carrying it forward stops being "the
        // last price" and becomes a stale one, which is the delay it would look
        // like on screen.
        //
        // A real trade happens at the bid or the ask, so a print outside the
        // current spread has been overtaken by definition. Clamping to the near
        // side keeps the number on the tick grid, tracks the market as it
        // moves, and needs no timer to decide when the memory expired.
        var carried = priorTrade
        if let bid = quote.bid, carried < bid { carried = bid }
        if let ask = quote.ask, carried > ask { carried = ask }

        quote.price = carried
        // Only still a *traded* price if the book didn't overrule it — the
        // strategy engine and the next carry-forward both read this flag.
        quote.tradePrice = carried == priorTrade ? priorTrade : nil
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
            .filter { !known.contains($0) && MarketSymbol($0) != nil }
    }

    // MARK: Strategy

    private func runStrategy() async {
        guard let plan = planSource.plan else { return }
        // Reviewing a past day's plan must not fire today's notifications off
        // its levels. `activatePinned()` is the deliberate way to arm one.
        guard !planSource.isPinned else { return }
        var bySymbol: [MarketSymbol: StockQuote] = [:]
        for (key, quote) in latest {
            if let symbol = MarketSymbol(key) { bySymbol[symbol] = quote }
        }
        guard !bySymbol.isEmpty else { return }

        let alerts = await engine.evaluate(plan: plan, quotes: bySymbol)
        for alert in alerts {
            // Exits red, entries green — the colour is the first thing read.
            // Deliberately *not* flipped per market: it marks what the
            // instruction does to your position, not which way the price went.
            let tint: Color = alert.isApproach ? .orange
                : (StocksFormat.tint(for: alert.levelKind))
            NotificationService.post(title: alert.title, body: alert.body, tint: tint,
                             identifier: alert.id, source: "stocks")
        }
    }

    /// Daily bars, twice a day at most, and Taiwan only — the endpoints behind
    /// `TWSEHistoryStore` are TWSE's and TPEX's own.
    ///
    /// The morning sweep is the one that matters and used to be missing: a plan
    /// that expresses volume relatively (`{"multiple": 1.5, "refAvgDays": 20}`
    /// rather than a hard 2602 張) can't be evaluated at all without the 20-day
    /// average, and an unmeasurable condition is treated as unmet — so waiting
    /// until after the close to fetch history meant those entries could never
    /// fire during the session they were written for. Yesterday's bars are all
    /// the average needs and they're available at any hour.
    ///
    /// The post-close sweep then picks up today's own bar, which is what the
    /// multi-session rules (`破X後3日內收回`) walk.
    private func sweepHistoryIfDue() async {
        guard planSource.plan != nil else { return }
        let today = Market.tw.tradingDay()
        let needsMorning = lastHistorySweepDay != today
        let needsPostClose = Market.tw.isAfterClose() && lastHistoryCloseSweepDay != today
        guard needsMorning || needsPostClose else { return }

        lastHistorySweepDay = today
        if Market.tw.isAfterClose() { lastHistoryCloseSweepDay = today }

        let symbols = (keysByMarket()[.tw] ?? []).compactMap { MarketSymbol($0) }
        await TWSEHistoryStore.shared.refresh(symbols: symbols, force: needsPostClose)
    }

    // MARK: Signal

    /// With a plan loaded, the plan is the news: a level that fired today, or
    /// one the price is sitting right on top of, is what deserves the card. The
    /// biggest-mover behaviour stays as the fallback for a watchlist with no
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
            headline: String(format: "%@ nearing %@ %@ (%.2f%%)",
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
        let open = mover.market.isOpen()
        // Below this, a stock has nothing time-sensitive to say — stay out of the
        // feed rather than filling it with routine noise. The threshold is higher
        // after the close, where a stale flat quote is even less worth a card.
        let floor: Double = open ? 3 : 5
        if magnitude < floor { return nil }

        let headline = String(format: "%@ %@%.2f%% · %@",
                              mover.name ?? mover.symbol, mover.isUp ? "+" : "−", magnitude,
                              StocksFormat.price(mover.price, market: mover.market))
        // Only a genuinely outsized move (≥8%) earns the elevated rank that leads
        // the brief; a merely notable one sits at normal, below anything urgent.
        let priority: GlanceSignal.Priority = magnitude >= 8 ? .elevated : .normal
        return GlanceSignal(priority: priority, score: magnitude,
                            headline: headline,
                            detail: open ? nil : "At last close",
                            systemImage: iconSystemName,
                            // The market's own convention, not this app's: a red
                            // 台積電 up-tick is what a Taipei screen shows.
                            tint: mover.market.tint(rising: mover.isUp),
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
}

// MARK: - Popover UI

/// The three sections the glance is split across. Tabs rather than one long
/// column: the watchlist, the portfolio and the trading plan are each a full
/// screen's worth on their own, and stacking all three is what made the glance
/// scroll. One is on screen at a time, chosen by the segmented control up top.
enum StocksSection: String, CaseIterable, Identifiable {
    case prices, holdings, plan
    var id: String { rawValue }

    var title: String {
        switch self {
        case .prices: return "Prices"
        case .holdings: return "Holdings"
        case .plan: return "Plan"
        }
    }
}

/// The glance's single rendering surface, shown in the 240pt menu column, the
/// standalone tool window, and Quick Switch alike. The plan board inside it
/// picks its own shape via `ViewThatFits` — see `StocksViews.swift`.
private struct StocksPopover: View {
    @Bindable var plugin: StocksPlugin

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Errors sit above the tabs, not inside one: a dead feed or an
            // unreadable plan file is worth seeing whichever section you're on,
            // and burying it under the wrong tab is how it goes unnoticed.
            if let err = plugin.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let planError = plugin.planSource.error {
                Label(planError, systemImage: "doc.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Section", selection: $plugin.selectedSection) {
                ForEach(StocksSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch plugin.selectedSection {
            case .prices:   pricesTab
            case .holdings: holdingsTab
            case .plan:     planTab
            }
        }
    }

    /// The watchlist, with the per-market feed heartbeat beneath it.
    private var pricesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plugin.quotes.isEmpty {
                Text("No quotes yet\u{2026}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(plugin.quotes) { quote in
                        StocksQuoteRow(quote: quote,
                                       showsMarketBadge: plugin.activeMarkets.count > 1)
                    }
                }
            }

            // Below the rows rather than above: it's a reassurance to glance
            // down at, not something to read before the prices. One line per
            // market, because "live" is a claim each feed has to make for itself
            // — Tokyo is shut while New York is mid-session, and a single
            // heartbeat would have to lie about one of them.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plugin.activeMarkets, id: \.self) { market in
                    StocksFeedStatus(market: market,
                                     labelled: plugin.activeMarkets.count > 1,
                                     lastFetch: plugin.lastFetch[market],
                                     quotedAt: plugin.quotedAt(for: market))
                }
            }
        }
    }

    private var holdingsTab: some View {
        StocksHoldingsSection(
            source: plugin.holdingsSource,
            quotes: plugin.quotesByKey,
            plannedIDs: Set(plugin.planSource.plan?.plans.map(\.stockId) ?? []))
    }

    /// Always available, even with no plan loaded: the import control lives
    /// inside it, so a plan has to be reachable from the glance itself.
    private var planTab: some View {
        StocksPlanBoard(source: plugin.planSource,
                        engine: plugin.engine,
                        quotes: plugin.quotesByKey,
                        selection: $plugin.selectedPlanStockID)
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
            Text("""
                 Comma-separated symbols, from any of three markets:
                 • Taiwan — TWSE-2330, TPEX-3491, or 2330.TW
                 • United States — AAPL, MSFT, BRK.B
                 • Japan — TSE-7203, or 7203.T

                 A bare four-digit code is read as Taiwan, so Japanese listings \
                 need the TSE- prefix or the .T suffix.
                 """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("TWSE-2330, AAPL, TSE-7203", text: $symbolsText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Save watchlist") {
                plugin.symbols = symbolsText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                    .filter { !$0.isEmpty }
                Task { await plugin.refresh() }
            }

            Text("""
                 Rises are drawn in each market's own colour — red for Taiwan and \
                 Japan, green for the United States. The ▲ / ▼ arrow means the \
                 same thing everywhere.
                 """)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("Trading plan")
                .font(.headline)
            Text("""
                 Pick a JSON file; it reloads automatically whenever you save it. \
                 You get a notification when the price reaches one of the plan's \
                 levels. See PLAN_SCHEMA.md for the format.
                 """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose plan file…") { plugin.planSource.chooseFile() }
                if plugin.planSource.displayPath != nil {
                    Button("Remove") { plugin.planSource.clear() }
                    Button("Reload") {
                        plugin.planSource.reload()
                        Task { await plugin.refresh() }
                    }
                }
            }
            if let path = plugin.planSource.displayPath {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let plan = plugin.planSource.plan {
                Text("Loaded \(plan.date ?? "?") · \(plan.plans.count) stocks")
                    .font(.caption).foregroundStyle(.green)
            }
            if let error = plugin.planSource.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            Text("Approach warnings")
                .font(.headline)
            Text("""
                 Send an early heads-up when the price closes to within these \
                 percentages of a level. Comma-separated; leave blank to switch \
                 them off. Each level fires each band at most once a day.
                 """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("10, 5, 2", text: $approachText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("Save") {
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
            Text("""
                 Provide a key for more reliable US quotes. Stored in Glancekit's \
                 credentials file, not in app preferences. Leave blank to use the \
                 keyless Yahoo source. Taiwan and Japan need no key — Finnhub's \
                 free tier doesn't cover them, so they stay on their own feeds \
                 either way.
                 """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
