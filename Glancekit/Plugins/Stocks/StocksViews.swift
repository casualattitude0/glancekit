import SwiftUI

// The Stocks glance renders into three very different containers, all from the
// single `popoverSection()` the plugin contract gives it:
//
//   • a 240pt column in the menu-bar popover (`ClassicPanelView`),
//   • its own standalone tool window (`preferredToolWindowSize`),
//   • the unified Quick Switch window, which reuses the tool-window body.
//
// A trading plan is dense — five levels, prose conditions, events, evidence —
// and cramming that into 240pt makes it unreadable, while writing for 240pt
// wastes the standalone window. So the section has two shapes chosen by
// `ViewThatFits`, the same approach Notes and Colors already use here:
//
//   • Two-pane — a stock list beside a full detail panel, when there's room.
//   • Single column — quotes, then compact level rows, in the narrow menu.
//
// `ViewThatFits` takes the first layout that actually fits, so the section can
// never overflow its container.

// MARK: - Shared formatting

/// Level naming and number formatting, in one place so the popover, the tool
/// window, the notification body and the Smart Panel headline all say the same
/// words for the same thing.
///
/// Everything here that varies by market takes a `Market` rather than guessing
/// from the number: a price, a volume and a colour all mean different things in
/// Taipei, New York and Tokyo, and a formatter that can't tell them apart is
/// where a Japanese share count starts being printed as Taiwanese lots.
enum StocksFormat {

    /// The plan's own vocabulary, in English. The plan file writes these as
    /// stable machine keys (`entry`, `cut`, …), so translating them here does
    /// not touch any file the user authored.
    static func levelLabel(_ kind: String) -> String {
        switch kind {
        case "entry": return "Entry"
        case "add": return "Add"
        case "trim": return "Trim"
        case "reduce": return "Reduce"
        case "cut": return "Stop"
        case "reentry": return "Re-entry"
        case "gate": return "Index gate"
        default: return kind
        }
    }

    /// Taiwanese and Japanese prices sit on coarse tick grids and are usually
    /// whole numbers; trailing ".00" on every level makes a ladder much harder
    /// to scan. US names are quoted in cents, where a bare "227.5" reads as a
    /// truncation rather than a price — so the trimming is per market.
    ///
    /// The market-less form keeps the Taiwan behaviour, which is what every
    /// plan-level call site wants.
    static func price(_ value: Double, market: Market = .tw) -> String {
        if market.trimsWholePrices, value == value.rounded() {
            return String(format: "%.0f", value)
        }
        return String(format: "%.\(market.priceDecimals)f", value)
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.2f%%", value >= 0 ? "+" : "−", abs(value))
    }

    /// The change the way a broker terminal writes it: an arrow, the move in
    /// points, then the percent. The arrow carries the sign, so the percent
    /// drops its own — "▲50 +2.18%" says up twice and reads as clutter at
    /// caption size.
    ///
    /// Direction is the arrow's job specifically because colour can't be
    /// trusted to do it alone: this glance now draws a Taipei rise in red and a
    /// New York rise in green, exactly as each market does, and on a menu-bar
    /// panel the arrow is also the only cue that survives for someone who can't
    /// separate the two hues.
    static func changeLine(points: Double, percent: Double, market: Market) -> String {
        guard points != 0 else { return "0.00%" }
        return String(format: "%@%@ %.2f%%",
                      Market.arrow(rising: points > 0),
                      price(abs(points), market: market), abs(percent))
    }

    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    private static func group(_ value: Double) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    /// Accumulated volume, in whatever unit the exchange reported it.
    ///
    /// Taiwan publishes 張 (lots), which is also the unit every strategy-plan
    /// volume condition is written in, so no conversion happens anywhere
    /// between the feed and the rule. Yahoo publishes shares for the US and
    /// Japan, where the numbers run to eight digits and only an abbreviated
    /// form fits a 240pt column.
    static func volume(_ value: Double, unit: Market.VolumeUnit) -> String {
        switch unit {
        case .lots:
            return group(value) + " lots"
        case .shares:
            if value >= 1_000_000 { return String(format: "%.1fM sh", value / 1_000_000) }
            if value >= 1_000 { return String(format: "%.0fK sh", value / 1_000) }
            return group(value) + " sh"
        }
    }

    /// A money amount in the market's own currency. Taiwan and Japan quote
    /// whole units in ordinary use; US amounts keep their cents.
    static func money(_ value: Double, market: Market) -> String {
        let digits = market == .us ? 2 : 0
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        let number = f.string(from: NSNumber(value: value)) ?? String(Int(value))
        return market.currencySymbol + number
    }

    /// A clock time in the market's own zone. A Taipei fill stamped in local
    /// time is a number you have to do arithmetic on before you can use it.
    static func time(_ date: Date, market: Market = .tw) -> String {
        market.time(date)
    }

    /// Red for the levels that take you out, green for the ones that put you in.
    ///
    /// Deliberately **not** flipped per market. This colours what an instruction
    /// does to your position, not which way the price moved — a stop is a bad
    /// outcome in Taipei and in New York alike, and flipping it would make the
    /// same ladder mean opposite things in two panels.
    static func tint(for kind: String) -> Color {
        switch kind {
        case "trim", "reduce", "cut": return .red
        case "entry", "add", "reentry": return .green
        default: return .secondary
        }
    }
}

// MARK: - Quotes

struct StocksQuoteRow: View {
    let quote: StockQuote
    var compact = true
    /// Shown only when the watchlist actually spans markets. On a single-market
    /// list the badge would be a constant, and a constant on every row is noise.
    var showsMarketBadge = false

    /// Direction of the most recent tick, or nil once it has faded. Drives a
    /// brief tint on the price so a change is visible at a glance — without it
    /// a live number and a frozen one look identical, which is exactly the
    /// ambiguity that made the stale-price bug hard to spot in the first place.
    @State private var tick: Bool?
    /// Compared against on each update. `quote` is a value, so the view has no
    /// other way to know what the previous price was.
    @State private var shownPrice: Double?
    /// Held so a new tick can cancel the previous fade. Without it, two ticks
    /// inside the fade window leave the older timer running, and it clears the
    /// newer tick's colour early — the flash visibly cuts out mid-fade.
    @State private var fade: Task<Void, Never>?
    /// Drives the filled flash: switched on instantly, then eased back out.
    /// Separate from `tick` because the two run on different clocks — the fill
    /// is one fast pulse, the tint lingers long enough afterwards to be read.
    @State private var blink = false

    /// The colour a tick is drawn in, in this row's own market's convention —
    /// a rise is red in Taipei and Tokyo, green in New York.
    private var tickTint: Color? {
        tick.map { quote.market.tint(rising: $0) }
    }

    /// White while the cell is filled — a saturated background leaves same-hue
    /// text unreadable — then the tick colour, then back to normal once the
    /// tick has faded.
    private var priceTint: Color {
        if blink { return .white }
        return tickTint ?? .primary
    }

    /// Limit up / limit down, where the exchange publishes daily limits (Taiwan,
    /// Japan). Compared against the exchange's own published numbers rather than
    /// a recomputed percentage, since the limits are rounded onto the tick grid
    /// and being a tick out here would report a locked stock as still trading.
    /// US equities have no daily limit, so this is simply never non-nil there.
    private var limitState: (label: String, tint: Color)? {
        if let up = quote.limitUp, quote.price >= up {
            return ("LIMIT UP", quote.market.tint(rising: true))
        }
        if let down = quote.limitDown, quote.price <= down {
            return ("LIMIT DOWN", quote.market.tint(rising: false))
        }
        return nil
    }

    /// Motion is decoration here; the colour carries the meaning. So with
    /// Reduce Motion on, the tint still appears and still clears, it just does
    /// so instantly rather than easing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.name ?? quote.symbol)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if showsMarketBadge {
                        Text(quote.market.badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 2))
                    }
                    if quote.name != nil {
                        Text(quote.symbol)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: compact ? 74 : 96, alignment: .leading)

            StocksSparkline(values: quote.series, up: quote.isUp, market: quote.market)
                .frame(width: compact ? 48 : 72, height: 22)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    if let limit = limitState {
                        Text(limit.label)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(limit.tint, in: RoundedRectangle(cornerRadius: 3))
                    }

                    // The flash fills the price cell the way a broker terminal
                    // marks a print. Still confined to this one Text: the fill
                    // is drawn as a background with negative padding, so it
                    // bleeds past the glyphs without adding any layout of its
                    // own and the row can't shift when it switches on.
                    Text(StocksFormat.price(quote.price, market: quote.market))
                        .font(.body.monospacedDigit())
                        .contentTransition(.numericText())
                        .foregroundStyle(priceTint)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(tickTint ?? .clear)
                                .opacity(blink ? 0.9 : 0)
                                .padding(.horizontal, -4)
                                .padding(.vertical, -1)
                        }
                }
                Text(StocksFormat.changeLine(points: quote.change,
                                             percent: quote.changePercent,
                                             market: quote.market))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.market.tint(rising: quote.isUp))
                    .contentTransition(.numericText())
                if let volume = quote.volume {
                    Text(StocksFormat.volume(volume, unit: quote.volumeUnit))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .contentTransition(.numericText())
                }
            }
            // Index levels run to five digits plus decimals, which wraps
            // mid-number in the 240pt menu column — "42671.2" above a lone "7".
            // Shrinking beats wrapping for a figure read at a glance.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        // Two layers, on the same clock. The whole row washes faintly so the
        // update is visible from across the panel without having to be looking
        // at the price, and the price cell fills solidly so the eye lands on
        // the number that actually moved. One alone reads as either too subtle
        // to notice or too loud to sit through every few seconds.
        //
        // Negative padding again: the wash bleeds past the row's bounds rather
        // than adding any, so nothing reflows when it switches on.
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tickTint ?? .clear)
                .opacity(blink ? 0.18 : 0)
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        }
        .onChange(of: quote.price, initial: true) { _, price in
            // The first value a row ever shows isn't a tick — seeding silently
            // keeps every row from flashing the moment the popover opens.
            guard let previous = shownPrice else {
                shownPrice = price
                return
            }
            shownPrice = price
            guard price != previous else { return }

            let rising = price > previous
            fade?.cancel()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { tick = rising }

            // Unanimated on, animated off — that asymmetry is what reads as a
            // flash rather than a throb. Skipped under Reduce Motion, where a
            // hard flash is the exact thing being asked to stop; the tint,
            // arrow and percent all still update.
            if !reduceMotion {
                blink = true
                withAnimation(.easeOut(duration: 0.45)) { blink = false }
            }
            fade = Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.5)) { tick = nil }
            }
        }
        .onDisappear { fade?.cancel() }
    }
}

/// Whether quotes are still arriving for one market, and how long since the
/// last one.
///
/// Per-row flashes only fire when a price *changes*, so on their own they can't
/// distinguish the two ways a screen full of unchanging numbers happens: a
/// quiet market, or a feed that died. That ambiguity is exactly what hid the
/// stale-price bug, so the heartbeat here is tied to the fetch succeeding
/// rather than to any price moving.
///
/// One of these per market, because "live" is a claim each feed has to make for
/// itself — Tokyo is shut while New York is mid-session, and a single row would
/// have to lie about one of them.
struct StocksFeedStatus: View {
    let market: Market
    /// Whether to name the market. Off on a single-market watchlist, where the
    /// name would be a constant repeated under every panel.
    var labelled = false
    let lastFetch: Date?
    /// The exchange's stamp on the data itself, as opposed to when we fetched
    /// it. Shown because the two differ by more than people expect.
    let quotedAt: Date?

    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Re-evaluated on a timer, not just when a quote lands: going stale is
        // the absence of an update, so nothing else would trigger a redraw and
        // the row would sit there claiming to be live indefinitely.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = state(at: context.date)
            let countdown = countdown(at: context.date)
            HStack(spacing: 5) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(beat ? 1.55 : 1)
                    .opacity(beat ? 1 : 0.75)
                if labelled {
                    Text(market.badge)
                        .font(.system(size: 9, weight: .semibold).monospaced())
                        .foregroundStyle(.tertiary)
                }
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let countdown {
                    // Monospaced so the row doesn't twitch as the digit counts
                    // down — a width that changes every second would undo the
                    // steadiness this is here to provide.
                    Text(countdown)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if let age = quoteAge(at: context.date) {
                    // The exchange's lag, stated rather than left to be felt as
                    // an unexplained gap against a broker terminal. Amber once
                    // it exceeds a snapshot interval, since past that the number
                    // on screen is genuinely behind the market, not just this
                    // panel's own polling.
                    // Erased because the two branches are different shape-style
                    // types — Color and HierarchicalShapeStyle don't unify.
                    Text(age.label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(age.late ? AnyShapeStyle(Color.orange)
                                                  : AnyShapeStyle(.tertiary))
                }
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel([market.displayName, state.label, countdown]
                .compactMap { $0 }.joined(separator: " "))
        }
        .onChange(of: lastFetch) {
            // One pulse per successful fetch. A repeating animation would look
            // identical whether or not data was arriving, which is the opposite
            // of what this is for.
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.15)) { beat = true }
            withAnimation(.easeIn(duration: 0.45).delay(0.15)) { beat = false }
        }
    }

    /// Seconds until the next fetch is due, or "Updating…" while one should be
    /// in flight. Nil outside the session, where the cadence drops to 15 minutes
    /// and a countdown that long is noise rather than reassurance.
    ///
    /// It stops once the feed is meaningfully late: past that the number would
    /// be counting toward something that isn't coming, and `state` has already
    /// switched to Delayed / Disconnected, which is the more honest thing to be
    /// reading.
    private func countdown(at now: Date) -> String? {
        let cadence = market.cadence(now)
        guard cadence <= 60, market.isOpen(now), let lastFetch else { return nil }
        let remaining = cadence - now.timeIntervalSince(lastFetch)
        guard remaining > -3 else { return nil }
        return remaining <= 0 ? "updating…" : String(format: "%.0fs", remaining.rounded(.up))
    }

    /// How old the data itself is, by the exchange's own stamp.
    ///
    /// Measured on 2026-07-20: Taiwan's MIS stamps a snapshot 5–6s behind its
    /// own server clock and only advances it every 15–20s, so 7–23s is the
    /// normal range and none of it is this app's doing. The threshold scales
    /// off the polling cadence so a once-a-minute market isn't flagged for
    /// being a minute old, which is simply what once-a-minute means.
    private func quoteAge(at now: Date) -> (label: String, late: Bool)? {
        guard market.isOpen(now), let quotedAt else { return nil }
        let age = now.timeIntervalSince(quotedAt)
        guard age >= 0 else { return nil }
        let tolerance = max(25, market.openCadence * 2)
        return (String(format: "quote −%.0fs", age), age > tolerance)
    }

    /// Thresholds are generous against the cadence: an exchange's own snapshot
    /// can repeat for ~25s, and a fetch can be queued behind the rate gate, so
    /// "late" only starts well past anything routine.
    private func state(at now: Date) -> (tint: Color, label: String) {
        guard market.isOpen(now) else {
            return (.secondary, lastFetch.map { "Closed · \(market.time($0))" } ?? "Closed")
        }
        guard let lastFetch else { return (.secondary, "No data yet") }
        let age = now.timeIntervalSince(lastFetch)
        let late = max(30, market.openCadence * 4)
        if age <= late { return (.green, "Live") }
        if age <= late * 4 { return (.orange, String(format: "Delayed %.0fs", age)) }
        return (.red, "Disconnected · \(market.time(lastFetch))")
    }
}

/// A minimal line chart for an intraday series, drawn in the market's own
/// up/down convention.
struct StocksSparkline: View {
    let values: [Double]
    let up: Bool
    var market: Market = .tw

    var body: some View {
        GeometryReader { geo in
            if values.count > 1, let lo = values.min(), let hi = values.max(), hi > lo {
                let w = geo.size.width
                let h = geo.size.height
                Path { path in
                    for (i, v) in values.enumerated() {
                        let x = w * CGFloat(i) / CGFloat(values.count - 1)
                        let y = h * (1 - CGFloat((v - lo) / (hi - lo)))
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(market.tint(rising: up), lineWidth: 1.5)
            } else {
                Rectangle().fill(.quaternary).frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

// MARK: - Plan board

/// The plan half of the glance: market verdict and gate up top, then either a
/// list-plus-detail pair or a single stacked column.
struct StocksPlanBoard: View {
    let source: StrategyPlanSource
    let engine: StrategyEngine
    let quotes: [String: StockQuote]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StocksPlanToolbar(source: source)
            StocksPlanStatus(source: source)

            if let plan {
                StocksMarketHeader(plan: plan,
                                   gateBreached: engine.gateBreached,
                                   index: indexQuote)

                ViewThatFits(in: .horizontal) {
                    twoPane
                    singleColumn
                }
            } else {
                StocksPlanEmptyState(source: source)
            }
        }
    }

    private var plan: StrategyPlan? { source.plan }

    /// Stock list on the left, the selected stock's full detail on the right.
    private var twoPane: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(plan?.plans ?? [], id: \.stockId) { stock in
                    StocksPlanListRow(
                        stock: stock,
                        rows: engine.statuses[stock.stockId] ?? [],
                        quote: quote(for: stock),
                        isSelected: selected?.stockId == stock.stockId,
                        action: { selection = stock.stockId }
                    )
                }
            }
            .frame(width: 168, alignment: .leading)

            Divider()
                .padding(.horizontal, 12)

            if let stock = selected {
                StocksStockDetail(
                    stock: stock,
                    rows: engine.statuses[stock.stockId] ?? [],
                    quote: quote(for: stock),
                    alerts: engine.recentAlerts.filter { $0.symbol == stock.symbol }
                )
                // `ViewThatFits` compares each candidate's *ideal* size against
                // the space on offer, and the ideal width of a Text is its
                // full unwrapped line — so without a stated ideal, one long
                // condition sentence makes this pane measure ~600pt and lose to
                // the single column in a window that could comfortably hold it.
                // Stating the ideal lets the prose still expand to fill a wider
                // window via `maxWidth`.
                .frame(idealWidth: 250, maxWidth: .infinity, alignment: .topLeading)
            }
        }
        // The floor is what makes `ViewThatFits` reject this shape in the
        // 240pt menu column and take the single column instead.
        .frame(minWidth: 430, alignment: .topLeading)
    }

    /// Every stock stacked, the selected one expanded inline — the narrow shape.
    private var singleColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(plan?.plans ?? [], id: \.stockId) { stock in
                let rows = engine.statuses[stock.stockId] ?? []
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        selection = (selection == stock.stockId) ? nil : stock.stockId
                    } label: {
                        StocksStockHeader(stock: stock, quote: quote(for: stock),
                                          isExpanded: selection == stock.stockId)
                    }
                    .buttonStyle(.plain)

                    StocksLevelLadder(rows: rows, price: quote(for: stock)?.price,
                                      market: stock.symbol?.market ?? .tw)

                    if selection == stock.stockId {
                        StocksStockDetail(
                            stock: stock,
                            rows: rows,
                            quote: quote(for: stock),
                            alerts: engine.recentAlerts.filter { $0.symbol == stock.symbol },
                            showsLadder: false
                        )
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    /// The weighted index, quoted whenever the plan defines a market gate.
    private var indexQuote: StockQuote? {
        quotes.first { MarketSymbol($0.key)?.isIndex == true }?.value
    }

    private var selected: StrategyPlan.StockPlan? {
        let all = plan?.plans ?? []
        return all.first { $0.stockId == selection } ?? all.first
    }

    /// Quotes are keyed by the watchlist spelling the user typed, which need not
    /// match the plan's `stockId` — so match on the parsed symbol, not the text.
    private func quote(for stock: StrategyPlan.StockPlan) -> StockQuote? {
        guard let symbol = stock.symbol else { return nil }
        return quotes.first { MarketSymbol($0.key) == symbol }?.value
    }
}

// MARK: - Holdings

/// The portfolio: what you hold, what it's worth, and — the part that matters —
/// which of it the plan has no exit rules for.
struct StocksHoldingsSection: View {
    let source: HoldingsSource
    let quotes: [String: StockQuote]
    /// Stock ids the loaded plan covers, for the uncovered-position warning.
    let plannedIDs: Set<String>

    @State private var isEditing = false
    @State private var copied = false
    /// Held so a second copy restarts the confirmation instead of inheriting
    /// the first one's countdown and clearing early.
    @State private var copiedReset: Task<Void, Never>?

    private func copyJSON() {
        guard let json = source.exportJSON() else { return }
        // Clearing first is required, not tidiness: NSPasteboard keeps whatever
        // types were written before, and a stale flavour can win when the
        // destination app asks for something other than plain text.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)

        copiedReset?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        copiedReset = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { copied = false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Holdings").font(.headline)
                if let updated = source.holdings?.updatedAt {
                    Text(updated)
                        .font(.caption)
                        .foregroundStyle(source.isStale ? .orange : .secondary)
                }
                Spacer(minLength: 0)
                if source.canEdit && !isEditing {
                    Button { isEditing = true } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .font(.caption).controlSize(.small).buttonStyle(.borderless)
                }
                if source.holdings != nil && !isEditing {
                    Button { copyJSON() } label: {
                        // The label doubles as the confirmation. A copy leaves
                        // no visible trace anywhere else, and a button that
                        // looks identical before and after reads as broken.
                        Label(copied ? "Copied" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .font(.caption).controlSize(.small).buttonStyle(.borderless)
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .help("Copy the full holdings JSON, in the file's own shape")
                }
                Button { source.chooseFile() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .font(.caption).controlSize(.small).buttonStyle(.borderless)
                if source.displayPath != nil && !isEditing {
                    Button { source.reload() } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .font(.caption).controlSize(.small).buttonStyle(.borderless)
                }
            }

            if let error = source.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if source.holdings == nil {
                Text("Import your daily holdings JSON and level alerts will be converted straight into share counts.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isEditing {
                // `id` forces a fresh editor (and a fresh draft) per session,
                // so reopening never shows a stale half-typed row.
                StocksHoldingsEditor(source: source, isEditing: $isEditing)
                    .id(source.holdings?.updatedAt ?? "-")
            } else if let holdings = source.holdings {
                if source.isStale {
                    Label("Holdings aren't from today — share counts may be out of date",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(holdings.positions) { position in
                    StocksHoldingRow(position: position,
                                     quote: quote(for: position),
                                     isPlanned: plannedIDs.contains(position.stockId))
                }

                StocksPortfolioTotals(holdings: holdings, quotes: quotes)

                // A position the plan never mentions has no stop, no trim and no
                // alert of any kind — it is the one thing here that can hurt you
                // while looking after itself.
                let uncovered = holdings.positions.filter { !plannedIDs.contains($0.stockId) }
                if !uncovered.isEmpty {
                    Label("No plan: \(uncovered.map(\.displayName).joined(separator: ", "))"
                          + " — not covered, so nothing will ever alert",
                          systemImage: "shield.slash")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func quote(for position: HoldingPosition) -> StockQuote? {
        guard let symbol = position.symbol else { return nil }
        return quotes.first { MarketSymbol($0.key) == symbol }?.value
    }
}

private struct StocksHoldingRow: View {
    let position: HoldingPosition
    let quote: StockQuote?
    let isPlanned: Bool

    private var market: Market { position.market }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(position.displayName).font(.caption.weight(.semibold))
                    if !isPlanned {
                        Image(systemName: "shield.slash")
                            .font(.system(size: 8)).foregroundStyle(.orange)
                    }
                }
                Text("\(Int(position.shares)) sh @ \(StocksFormat.price(position.avgCost, market: market))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let quote {
                let pl = position.profit(at: quote.price)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(StocksFormat.money(position.marketValue(at: quote.price), market: market))
                        .font(.caption.monospacedDigit())
                    Text("\(pl >= 0 ? "+" : "−")\(StocksFormat.money(abs(pl), market: market))  "
                         + StocksFormat.signedPercent(position.profitPercent(at: quote.price)))
                        .font(.caption2.monospacedDigit())
                        // A gain is red in Taipei and Tokyo, green in New York —
                        // the same convention the price rows use.
                        .foregroundStyle(market.tint(rising: pl >= 0))
                }
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

/// Portfolio value, **one line per currency**.
///
/// Summing a Tokyo position and a Taipei one into a single number would be
/// arithmetic on incompatible units dressed up as a total — 100 JPY added to
/// 100 TWD is not 200 of anything. Converting them would need an FX rate this
/// glance doesn't fetch and couldn't timestamp honestly. So each currency is
/// totalled separately and left that way.
private struct StocksPortfolioTotals: View {
    let holdings: Holdings
    let quotes: [String: StockQuote]

    private struct Total {
        let market: Market
        var value: Double = 0
        var cost: Double = 0
        var profit: Double { value - cost }
    }

    var body: some View {
        let priced = holdings.positions.compactMap { position -> (HoldingPosition, Double)? in
            guard let symbol = position.symbol,
                  let quote = quotes.first(where: { MarketSymbol($0.key) == symbol })?.value
            else { return nil }
            return (position, quote.price)
        }

        var byMarket: [Market: Total] = [:]
        for (position, price) in priced {
            var total = byMarket[position.market] ?? Total(market: position.market)
            total.value += position.marketValue(at: price)
            total.cost += position.costBasis
            byMarket[position.market] = total
        }
        let totals = Market.allCases.compactMap { byMarket[$0] }

        return VStack(alignment: .leading, spacing: 1) {
            Divider().padding(.vertical, 2)
            ForEach(totals, id: \.market) { total in
                HStack(spacing: 6) {
                    Text((totals.count > 1 ? "\(total.market.badge) " : "")
                         + "Value \(StocksFormat.money(total.value, market: total.market))")
                        .font(.caption.weight(.medium).monospacedDigit())
                    if total.cost > 0 {
                        Text("\(total.profit >= 0 ? "+" : "−")"
                             + StocksFormat.money(abs(total.profit), market: total.market) + "  "
                             + StocksFormat.signedPercent(total.profit / total.cost * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(total.market.tint(rising: total.profit >= 0))
                    }
                    Spacer(minLength: 0)
                }
            }
            if let cash = holdings.cash {
                let market = holdings.cashMarket
                // Cash is added to its own market's value only. Where the
                // portfolio spans currencies there is no single "grand total"
                // to print, and inventing one would be the exact conversion
                // this view refuses to guess at.
                let sameMarket = byMarket[market]?.value ?? 0
                Text("Cash \(StocksFormat.money(cash, market: market))"
                     + (totals.count <= 1
                        ? "  Total \(StocksFormat.money(sameMarket + cash, market: market))"
                        : "  \(market.badge) total \(StocksFormat.money(sameMarket + cash, market: market))"))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if priced.count < holdings.positions.count {
                Text("(\(holdings.positions.count - priced.count) not yet quoted, excluded)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

// MARK: - Holdings editor

/// One editable row. Fields are strings while editing so a half-typed number
/// ("2", "24", "240") doesn't have to be a valid `Double` at every keystroke,
/// and so clearing a field doesn't silently become 0.
struct HoldingDraftRow: Identifiable, Equatable {
    var id = UUID()
    var stockId: String = ""
    var name: String = ""
    var shares: String = ""
    var avgCost: String = ""
}

/// In-place editing of the portfolio, written back to the same JSON file.
struct StocksHoldingsEditor: View {
    let source: HoldingsSource
    @Binding var isEditing: Bool

    @State private var rows: [HoldingDraftRow] = []
    @State private var cash: String = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // Sized for the 240pt menu column: the code is fixed
                        // width, the name takes whatever is left, so the row
                        // never pushes the delete button off the edge.
                        TextField("TWSE-2330", text: $row.stockId)
                            .frame(width: 84)
                        TextField("Name", text: $row.name)
                            .frame(minWidth: 40)
                        Button {
                            rows.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                    HStack(spacing: 4) {
                        TextField("Shares", text: $row.shares)
                            .frame(width: 64)
                        Text("sh @").font(.caption2).foregroundStyle(.secondary)
                        TextField("Avg cost", text: $row.avgCost)
                            .frame(width: 70)
                        Spacer(minLength: 0)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
            }

            HStack(spacing: 6) {
                Button {
                    rows.append(HoldingDraftRow())
                } label: {
                    Label("Add a row", systemImage: "plus")
                }
                .buttonStyle(.borderless).font(.caption)

                Spacer(minLength: 0)

                Text("Cash").font(.caption2).foregroundStyle(.secondary)
                TextField("0", text: $cash)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .frame(width: 78)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Saving rewrites the watched file, so say what that costs before
            // the button rather than after.
            Text("Saving writes back to the holdings file. Re-exporting from your trade log will overwrite these edits.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Save") { commit() }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { isEditing = false }
            }
            .controlSize(.small)
        }
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        rows = (source.holdings?.positions ?? []).map { position in
            HoldingDraftRow(stockId: position.stockId,
                            name: position.name ?? "",
                            shares: trimmed(position.shares),
                            avgCost: trimmed(position.avgCost))
        }
        cash = source.holdings?.cash.map(trimmed) ?? ""
    }

    /// 36.0 → "36", 830.7 → "830.7".
    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func commit() {
        var positions: [HoldingPosition] = []
        for row in rows {
            let id = row.stockId.trimmingCharacters(in: .whitespaces).uppercased()
            // A blank row is how you abandon an "Add a row" you thought better of.
            if id.isEmpty && row.shares.isEmpty && row.avgCost.isEmpty { continue }
            guard !id.isEmpty else { problem = "A row is missing its symbol"; return }
            guard MarketSymbol(id) != nil else {
                problem = "Can't read the symbol \(id) — use TPEX-3491 for Taipei OTC, TSE-7203 for Tokyo"
                return
            }
            guard let shares = Double(row.shares.trimmingCharacters(in: .whitespaces)),
                  shares >= 0 else {
                problem = "\(id): shares isn't a number"; return
            }
            guard let cost = Double(row.avgCost.trimmingCharacters(in: .whitespaces)),
                  cost >= 0 else {
                problem = "\(id): average cost isn't a number"; return
            }
            guard !positions.contains(where: { $0.stockId == id }) else {
                problem = "\(id) appears twice"; return
            }
            positions.append(HoldingPosition(
                stockId: id,
                name: row.name.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : row.name.trimmingCharacters(in: .whitespaces),
                shares: shares, avgCost: cost))
        }

        let cashText = cash.trimmingCharacters(in: .whitespaces)
        var cashValue: Double?
        if !cashText.isEmpty {
            guard let parsed = Double(cashText), parsed >= 0 else {
                problem = "Cash isn't a number"; return
            }
            cashValue = parsed
        }

        // The currency is carried through untouched: it is a property of the
        // account, not of anything editable on this sheet.
        let edited = Holdings(updatedAt: Market.tw.tradingDay(),
                              cash: cashValue,
                              currency: source.holdings?.currency,
                              positions: positions)
        if let failure = source.save(edited) {
            problem = failure
        } else {
            problem = nil
            isEditing = false
        }
    }
}

// MARK: - Import & history

/// Import and history controls, on the glance itself rather than in Settings.
///
/// Importing the morning's plan and glancing back at yesterday's are daily
/// actions on the thing you are already looking at; routing them through a
/// settings window would tax them every single day.
struct StocksPlanToolbar: View {
    let source: StrategyPlanSource

    var body: some View {
        HStack(spacing: 8) {
            Button { source.chooseFile() } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Choose the daily trading-plan JSON")

            if !source.archives.isEmpty {
                Menu {
                    ForEach(source.archives) { archive in
                        Button("\(archive.date)  ·  \(archive.stockCount) stocks") {
                            source.loadArchive(archive)
                        }
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Load an earlier plan")
            }

            if source.isPinned {
                Button { source.goLive() } label: {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Return to the plan file being watched")
            } else if source.displayPath != nil {
                Button { source.reload() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .controlSize(.small)
        .buttonStyle(.borderless)
        .lineLimit(1)
    }
}

/// Says out loud when what you're reading isn't today's live plan — the two
/// states in which the levels on screen can quietly mean something other than
/// what they appear to.
struct StocksPlanStatus: View {
    let source: StrategyPlanSource

    var body: some View {
        if source.isPinned {
            VStack(alignment: .leading, spacing: 4) {
                Label("Viewing the \(source.pinnedArchiveDate ?? "") plan · alerts paused",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                // Reviewing an old plan and trading one are different intents,
                // so arming it is a deliberate second tap rather than a guess.
                Button("Make this the active plan") { source.activatePinned() }
                    .font(.caption2)
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        } else if source.isStale, let date = source.plan?.date {
            // A plan more than a day old quotes moving averages that have moved.
            Label("Plan dated \(date), not today", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the plan area shows before any plan exists — with the import button
/// right there, so the feature is discoverable from the glance itself.
struct StocksPlanEmptyState: View {
    let source: StrategyPlanSource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No trading plan loaded", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Import your daily plan JSON and you'll get a notification when the price reaches a level. It reloads automatically whenever you save the file.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Import plan…") { source.chooseFile() }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Market header

struct StocksMarketHeader: View {
    let plan: StrategyPlan
    let gateBreached: Bool
    var index: StockQuote?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Trading plan").font(.headline)
                if let date = plan.date {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let structure = plan.market?.structure {
                    Text(structure)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }

            if let verdict = plan.market?.verdict {
                Text(verdict).font(.caption).foregroundStyle(.secondary)
            }

            // The gate is the loudest thing on the board when it's broken —
            // it changes what every other row means.
            if gateBreached {
                Label("Index below the gate · new-position alerts stopped",
                      systemImage: "exclamationmark.octagon.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            } else if let line = plan.market?.gate?.rungs.first {
                // The gate line alone is half the story — what decides whether
                // any entry alert can fire today is the gap between it and the
                // live index, so show both together.
                HStack(spacing: 4) {
                    Text("Index gate \(StocksFormat.price(line))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let index {
                        Text("· now \(StocksFormat.price(index.price))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(StocksFormat.signedPercent((index.price - line) / line * 100))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(index.price - line < line * 0.01 ? .orange : .secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                // The remaining rungs, so the staircase down to "new positions
                // stop" is visible before you're standing on the last step.
                if let rungs = plan.market?.gate?.rungs, rungs.count > 1 {
                    Text("Gate ladder " + rungs.map { StocksFormat.price($0) }.joined(separator: " → ")
                         + " (only the last rung halts new positions)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let note = plan.market?.usWatch?.note {
                Label(note, systemImage: "globe.americas")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Stock rows

/// A row in the two-pane list: name, flag, and how far the nearest live level is.
struct StocksPlanListRow: View {
    let stock: StrategyPlan.StockPlan
    let rows: [LevelStatus]
    let quote: StockQuote?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(stock.displayName).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    if let quote {
                        Text(StocksFormat.price(quote.price, market: quote.market))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(quote.market.tint(rising: quote.isUp))
                    }
                }
                HStack(spacing: 5) {
                    if let flag = stock.flag {
                        Text(flag)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let nearest {
                        Text("\(StocksFormat.levelLabel(nearest.kind)) \(StocksFormat.signedPercent(nearest.distancePercent ?? 0))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(abs(nearest.distancePercent ?? 99) <= 1 ? .orange : .secondary)
                    }
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The live level the price is closest to — the one that will fire next.
    private var nearest: LevelStatus? {
        rows.filter { !$0.isAdvisoryOnly && !$0.hasFired && $0.distancePercent != nil }
            .min { abs($0.distancePercent!) < abs($1.distancePercent!) }
    }
}

/// The tappable header used in the single-column shape.
struct StocksStockHeader: View {
    let stock: StrategyPlan.StockPlan
    let quote: StockQuote?
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(stock.displayName).font(.subheadline.weight(.semibold))
            if let flag = stock.flag {
                Text(flag)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 0)
            if let quote {
                Text(StocksFormat.price(quote.price, market: quote.market))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.market.tint(rising: quote.isUp))
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Level ladder

/// The plan's levels as a price ladder, with the live price slotted into its
/// true position among them.
///
/// This is the view the whole glance exists for. A list of levels tells you the
/// numbers; a ladder tells you *where you are* — whether the next thing to
/// happen is a stop or an entry, and how much room is left before it. Reading
/// that off five separate percentage figures takes real effort, and it's
/// exactly the judgement you want to be instant when the market is moving.
struct StocksLevelLadder: View {
    let rows: [LevelStatus]
    let price: Double?
    /// Only used for number formatting — the rung colours come from what each
    /// level *does* (see `StocksFormat.tint(for:)`), which doesn't flip by
    /// market.
    var market: Market = .tw

    var body: some View {
        let rungs = rungs()
        if rungs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rungs) { rung in
                    switch rung.content {
                    case .level(let status, let isCurrent):
                        levelRung(status, isCurrent: isCurrent)
                    case .price(let value):
                        priceRung(value)
                    }
                }
            }
        }
    }

    /// `isCurrent` means the price is sitting exactly on this level, so this
    /// rung *is* the price marker. The action label stays put and keeps its
    /// colour — losing track of what to do at the one price where you're
    /// standing is the worst possible moment to lose it.
    private func levelRung(_ status: LevelStatus, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            Text(status.line.map { StocksFormat.price($0, market: market) } ?? "—")
                .font(.caption.monospacedDigit().weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(width: 46, alignment: .trailing)

            Rectangle()
                .fill(StocksFormat.tint(for: status.kind).opacity(status.hasFired ? 0.9 : 0.45))
                .frame(width: 14, height: isCurrent ? 2 : 1.5)

            Text(StocksFormat.levelLabel(status.kind))
                .font(.caption2.weight(.medium))
                .foregroundStyle(StocksFormat.tint(for: status.kind))

            if let band = status.band, band.count >= 2 {
                Text("\(StocksFormat.price(band[0], market: market))–\(StocksFormat.price(band[band.count - 1], market: market))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if status.hasFired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            } else if status.needsHistory {
                // This level cannot fire yet. Saying so beats looking armed.
                Text("needs bars")
                    .font(.caption2).foregroundStyle(.orange)
            } else if status.isSuppressedByGate {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if status.isAdvisoryOnly {
                Text("advisory").font(.caption2).foregroundStyle(.tertiary)
            }

            // Last in the row, so "Now" lands on the same right-hand edge
            // whether or not this level also carries a status marker — a label
            // that shifts left when a checkmark appears is one the eye has to
            // hunt for on the very rung it should find fastest.
            if isCurrent { currentPriceTag }
        }
        .frame(height: 18)
        .padding(.vertical, isCurrent ? 1 : 0)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func priceRung(_ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(StocksFormat.price(value, market: market))
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 46, alignment: .trailing)

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 2)

            Spacer(minLength: 0)

            currentPriceTag
        }
        .frame(height: 20)
        .padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    /// One definition, used by both rung shapes, so the tag can't drift between
    /// the standalone marker and the one merged onto a level.
    private var currentPriceTag: some View {
        Text("NOW")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.accentColor)
    }

    private struct Rung: Identifiable {
        enum Content { case level(LevelStatus, isCurrent: Bool), price(Double) }
        let id: String
        let content: Content
    }

    /// Both sides come off the same tick grid, so this is an equality test that
    /// tolerates the float round trip rather than a proximity test.
    private func sitsOn(_ line: Double?, _ price: Double) -> Bool {
        guard let line else { return false }
        return abs(line - price) < 0.0001
    }

    /// Levels high-to-low with the live price inserted where it actually sits.
    /// Levels without a resolvable line (a prose-only `reentry`) have no rung —
    /// they'd have no position on the ladder, and inventing one would misplace
    /// the price marker relative to everything else.
    private func rungs() -> [Rung] {
        let sorted = rows
            .filter { $0.line != nil }
            .sorted { ($0.line ?? 0) > ($1.line ?? 0) }

        // When the price sits exactly on a level, that level becomes the price
        // marker instead of getting its own rung beside it. Two rungs showing
        // the same number read as one row that lost its action label — and the
        // level you're standing on is the one whose instruction you most need.
        //
        // Every level at that price is marked, not just the first: a plan can
        // put a trim and a re-entry on the same line, and picking one to
        // highlight would hide the other behind the very marker meant to draw
        // the eye.
        var out = sorted.map { status in
            Rung(id: status.id,
                 content: .level(status, isCurrent: price.map { sitsOn(status.line, $0) } ?? false))
        }

        guard let price, !sorted.contains(where: { sitsOn($0.line, price) }) else { return out }
        let insertAt = out.firstIndex { rung in
            if case .level(let status, _) = rung.content { return (status.line ?? 0) < price }
            return false
        } ?? out.count
        out.insert(Rung(id: "__price", content: .price(price)), at: insertAt)
        return out
    }
}

// MARK: - Stock detail

/// Everything the plan says about one stock: the ladder, each level's prose and
/// position size, today's alerts, what to watch, upcoming events, and the
/// evidence the plan was built on.
///
/// Prose that comes out of the plan file — conditions, sources, notes, watch
/// items — is rendered verbatim, in whatever language it was written in. It is
/// the user's own writing, and a mis-glossed trade instruction is a much worse
/// failure than an untranslated one.
struct StocksStockDetail: View {
    let stock: StrategyPlan.StockPlan
    let rows: [LevelStatus]
    let quote: StockQuote?
    let alerts: [StrategyAlert]
    var showsLadder = true

    private var market: Market { stock.symbol?.market ?? .tw }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsLadder {
                header
                StocksLevelLadder(rows: rows, price: quote?.price, market: market)
            }

            if !alerts.isEmpty {
                detailGroup("Today's alerts") {
                    ForEach(alerts) { alert in
                        HStack(alignment: .top, spacing: 6) {
                            Text(StocksFormat.time(alert.firedAt, market: market))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            // An approach warning and a real trigger must never
                            // look alike in a list you scan in a hurry.
                            if let band = alert.approachBand {
                                Text("nearing \(StocksFormat.levelLabel(alert.levelKind)) "
                                     + (alert.approachBandIsTWD
                                        ? StocksFormat.money(band, market: market)
                                        : StocksFormat.price(band, market: market) + "%"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("\(StocksFormat.levelLabel(alert.levelKind)) \(StocksFormat.price(alert.price, market: market))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(StocksFormat.tint(for: alert.levelKind))
                            }
                        }
                    }
                }
            }

            // The prose is the part you actually act on, so each level gets its
            // condition in full rather than truncated to a number.
            detailGroup("Level conditions") {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(StocksFormat.levelLabel(row.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StocksFormat.tint(for: row.kind))
                            if let line = row.line {
                                Text(StocksFormat.price(line, market: market))
                                    .font(.caption.monospacedDigit())
                            }
                            // The quantity is the actionable half of a level and
                            // gets weight to match — not a grey footnote. Shown
                            // verbatim: it is a trade instruction.
                            if let action = row.size?.action {
                                Text(action)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(StocksFormat.tint(for: row.kind).opacity(0.15),
                                                in: Capsule())
                                    .foregroundStyle(StocksFormat.tint(for: row.kind))
                            }
                            if let after = row.size?.after {
                                Text("→ \(after)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            // The fraction is the plan's language; the share
                            // count is what you type into a broker.
                            if let shares = row.instruction?.shares {
                                Text("≈ \(shares) sh")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(row.instruction?.isShort == true ? .orange : .primary)
                            } else if let note = row.instruction?.note {
                                Text(note).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        if let condition = row.condition {
                            Text(condition)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if row.instruction?.isShort == true,
                           let affordable = row.instruction?.affordableShares {
                            Text("Cash covers only \(affordable) sh")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        if let source = row.source {
                            Text(source)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }

            if let band = stock.target?.band, band.count >= 2 {
                detailGroup("Target") {
                    HStack(spacing: 5) {
                        Text("\(StocksFormat.price(band[0], market: market))–\(StocksFormat.price(band[band.count - 1], market: market))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                        if let quote, band[0] > 0 {
                            Text("\(StocksFormat.signedPercent((band[0] - quote.price) / quote.price * 100)) to go")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let source = stock.target?.source {
                        Text(source).font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let path = stock.positionPath {
                detailGroup("Position ladder") {
                    if let up = path.up, !up.isEmpty {
                        Text("Up: \(up.joined(separator: " → "))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                    }
                    if let down = path.down, !down.isEmpty {
                        Text("Down: \(down.joined(separator: " → "))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.red)
                    }
                    if let max = path.max {
                        Text("Cap \(max)").font(.caption2.weight(.medium))
                    }
                    if let note = path.note {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let watch = stock.watchToday, !watch.isEmpty {
                detailGroup("Watch today") {
                    ForEach(Array(watch.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: "circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }

            if let events = stock.events, !events.isEmpty {
                detailGroup("Events") {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        HStack(alignment: .top, spacing: 6) {
                            Text(event.date ?? "—")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(eventLabel(event))
                                    .font(.caption2.weight(.medium))
                                if let note = event.note {
                                    Text(note)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            // Without this the row sizes to the note's full
                            // unwrapped width, overflows the pane, and drags
                            // the note off to the right instead of wrapping.
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if let evidence = stock.evidence, !evidence.isEmpty {
                detailGroup("Basis") {
                    ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                        Text(item.value ?? item.item ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(stock.displayName).font(.subheadline.weight(.semibold))
            if let flag = stock.flag {
                Text(flag)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            if let score = stock.score {
                Text("score \(score)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let quote {
                Text(StocksFormat.signedPercent(quote.changePercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.market.tint(rising: quote.isUp))
            }
        }
    }

    /// Known event types get an English name; anything else is passed through
    /// as the plan wrote it, so a new event type shows up rather than vanishing.
    private func eventLabel(_ event: StrategyPlan.PlanEvent) -> String {
        let name: String
        switch event.type {
        case "ex_dividend": name = "Ex-dividend"
        case "monthly_revenue": name = "Monthly revenue"
        case "earnings": name = "Earnings"
        case "fomc": name = "FOMC"
        default: name = event.type ?? "Event"
        }
        guard let value = event.value else { return name }
        return "\(name) \(StocksFormat.price(value, market: market))"
    }

    @ViewBuilder
    private func detailGroup<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

/// A tight bullet, since `Label` with an SF Symbol is far too loud at caption2.
private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text("·").font(.caption2)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
