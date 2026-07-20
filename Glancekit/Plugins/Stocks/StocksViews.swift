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
enum StocksFormat {
    static func levelLabel(_ kind: String) -> String {
        switch kind {
        case "entry": return "進場"
        case "add": return "加碼"
        case "trim": return "減碼"
        case "reduce": return "減倉"
        case "cut": return "停損"
        case "reentry": return "重進"
        default: return kind
        }
    }

    /// Taiwan prices are quoted to 2dp but are usually whole ticks; trailing
    /// ".00" on every level makes a ladder much harder to scan.
    static func price(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.2f", value)
    }

    static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.2f%%", value >= 0 ? "+" : "−", abs(value))
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TWMarketClock.timeZone
        return f.string(from: date)
    }

    /// Red for the levels that take you out, green for the ones that put you in.
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
    /// Drives the blink itself: dropped to dim instantly, then eased back up.
    /// Separate from `tick` because the two run on different clocks — the dim
    /// is a single fast blink, the colour lingers long enough to be read.
    @State private var blink = false

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
                if quote.name != nil {
                    Text(quote.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: compact ? 74 : 96, alignment: .leading)

            StocksSparkline(values: quote.series, up: quote.isUp)
                .frame(width: compact ? 48 : 72, height: 22)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                // The flicker is confined to this one Text. Monospaced digits
                // mean it can dim and recolour in place without the row
                // reflowing, which is what makes a blink readable here rather
                // than distracting.
                Text(StocksFormat.price(quote.price))
                    .font(.body.monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(tick.map { $0 ? Color.green : .red } ?? .primary)
                    .opacity(blink ? 0.2 : 1)
                Text(StocksFormat.signedPercent(quote.changePercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.isUp ? .green : .red)
                    .contentTransition(.numericText())
            }
            // Index levels run to five digits plus decimals, which wraps
            // mid-number in the 240pt menu column — "42671.2" above a lone "7".
            // Shrinking beats wrapping for a figure read at a glance.
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
        .onChange(of: quote.price, initial: true) { _, price in
            // The first value a row ever shows isn't a tick — seeding silently
            // keeps every row from flashing green the moment the popover opens.
            guard let previous = shownPrice else {
                shownPrice = price
                return
            }
            shownPrice = price
            guard price != previous else { return }

            let rising = price > previous
            fade?.cancel()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { tick = rising }

            // Unanimated down, animated back up — that asymmetry is the blink.
            // Skipped under Reduce Motion, where a rapid opacity swing is the
            // exact thing being asked to stop; the colour still carries it.
            if !reduceMotion {
                blink = true
                withAnimation(.easeOut(duration: 0.24)) { blink = false }
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

/// Whether quotes are still arriving, and how long since the last one.
///
/// Per-row flashes only fire when a price *changes*, so on their own they can't
/// distinguish the two ways a screen full of unchanging numbers happens: a
/// quiet market, or a feed that died. That ambiguity is exactly what hid the
/// stale-price bug, so the heartbeat here is tied to the fetch succeeding
/// rather than to any price moving.
struct StocksFeedStatus: View {
    let lastFetch: Date?

    @State private var beat = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Re-evaluated on a timer, not just when a quote lands: going stale is
        // the absence of an update, so nothing else would trigger a redraw and
        // the row would sit there claiming to be live indefinitely.
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let state = state(at: context.date)
            HStack(spacing: 5) {
                Circle()
                    .fill(state.tint)
                    .frame(width: 6, height: 6)
                    .scaleEffect(beat ? 1.55 : 1)
                    .opacity(beat ? 1 : 0.75)
                Text(state.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(state.label)
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

    /// Thresholds are generous against the 5s cadence: the exchange's own
    /// snapshot can repeat for ~25s, and a fetch can be queued behind the rate
    /// gate, so "late" only starts well past anything routine.
    private func state(at now: Date) -> (tint: Color, label: String) {
        guard TWMarketClock.isOpen(now) else {
            return (.secondary, lastFetch.map { "已收盤 · \(StocksFormat.time($0))" } ?? "已收盤")
        }
        guard let lastFetch else { return (.secondary, "尚未更新") }
        let age = now.timeIntervalSince(lastFetch)
        if age <= 30 { return (.green, "即時") }
        if age <= 120 { return (.orange, String(format: "延遲 %.0f 秒", age)) }
        return (.red, "連線中斷 · \(StocksFormat.time(lastFetch))")
    }
}

/// A minimal line chart for an intraday series.
struct StocksSparkline: View {
    let values: [Double]
    let up: Bool

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
                .stroke(up ? Color.green : Color.red, lineWidth: 1.5)
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
                // 條件 sentence makes this pane measure ~600pt and lose to the
                // single column in a window that could comfortably hold it.
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

                    StocksLevelLadder(rows: rows, price: quote(for: stock)?.price)

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
        quotes.first { TWSymbol($0.key)?.isIndex == true }?.value
    }

    private var selected: StrategyPlan.StockPlan? {
        let all = plan?.plans ?? []
        return all.first { $0.stockId == selection } ?? all.first
    }

    /// Quotes are keyed by the watchlist spelling the user typed, which need not
    /// match the plan's `stockId` — so match on the parsed symbol, not the text.
    private func quote(for stock: StrategyPlan.StockPlan) -> StockQuote? {
        guard let symbol = stock.symbol else { return nil }
        return quotes.first { TWSymbol($0.key) == symbol }?.value
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("持股").font(.headline)
                if let updated = source.holdings?.updatedAt {
                    Text(updated)
                        .font(.caption)
                        .foregroundStyle(source.isStale ? .orange : .secondary)
                }
                Spacer(minLength: 0)
                if source.canEdit && !isEditing {
                    Button { isEditing = true } label: {
                        Label("編輯", systemImage: "pencil")
                    }
                    .font(.caption).controlSize(.small).buttonStyle(.borderless)
                }
                Button { source.chooseFile() } label: {
                    Label("匯入", systemImage: "square.and.arrow.down")
                }
                .font(.caption).controlSize(.small).buttonStyle(.borderless)
                if source.displayPath != nil && !isEditing {
                    Button { source.reload() } label: {
                        Label("重載", systemImage: "arrow.clockwise")
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
                Text("匯入每日持股 JSON，關卡通知就會直接換算成股數。")
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
                    Label("持股非今日資料，股數換算可能已過時",
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
                    Label("無計畫：\(uncovered.map(\.displayName).joined(separator: "、"))　"
                          + "（不在計畫內，不會有任何通知）",
                          systemImage: "shield.slash")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func quote(for position: HoldingPosition) -> StockQuote? {
        guard let symbol = position.symbol else { return nil }
        return quotes.first { TWSymbol($0.key) == symbol }?.value
    }
}

private struct StocksHoldingRow: View {
    let position: HoldingPosition
    let quote: StockQuote?
    let isPlanned: Bool

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
                Text("\(Int(position.shares)) 股 @ \(StocksFormat.price(position.avgCost))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let quote {
                let pl = position.profit(at: quote.price)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(money(position.marketValue(at: quote.price)))
                        .font(.caption.monospacedDigit())
                    Text("\(pl >= 0 ? "+" : "−")\(money(abs(pl)))　"
                         + StocksFormat.signedPercent(position.profitPercent(at: quote.price)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(pl >= 0 ? .green : .red)
                }
            } else {
                Text("—").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(Int(v))
    }
}

private struct StocksPortfolioTotals: View {
    let holdings: Holdings
    let quotes: [String: StockQuote]

    var body: some View {
        let priced = holdings.positions.compactMap { position -> (HoldingPosition, Double)? in
            guard let symbol = position.symbol,
                  let quote = quotes.first(where: { TWSymbol($0.key) == symbol })?.value
            else { return nil }
            return (position, quote.price)
        }
        let value = priced.reduce(0) { $0 + $1.0.marketValue(at: $1.1) }
        let cost = priced.reduce(0) { $0 + $1.0.costBasis }
        let pl = value - cost

        VStack(alignment: .leading, spacing: 1) {
            Divider().padding(.vertical, 2)
            HStack(spacing: 6) {
                Text("市值 \(money(value))").font(.caption.weight(.medium).monospacedDigit())
                if cost > 0 {
                    Text("\(pl >= 0 ? "+" : "−")\(money(abs(pl)))　"
                         + StocksFormat.signedPercent(pl / cost * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(pl >= 0 ? .green : .red)
                }
                Spacer(minLength: 0)
            }
            if let cash = holdings.cash {
                Text("現金 \(money(cash))　總計 \(money(value + cash))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            if priced.count < holdings.positions.count {
                Text("（\(holdings.positions.count - priced.count) 檔尚無報價，未計入）")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(Int(v))
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
                        TextField("名稱", text: $row.name)
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
                        TextField("股數", text: $row.shares)
                            .frame(width: 64)
                        Text("股 @").font(.caption2).foregroundStyle(.secondary)
                        TextField("均價", text: $row.avgCost)
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
                    Label("新增一檔", systemImage: "plus")
                }
                .buttonStyle(.borderless).font(.caption)

                Spacer(minLength: 0)

                Text("現金").font(.caption2).foregroundStyle(.secondary)
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
            Text("儲存會寫回持股檔；之後從交易紀錄重新匯出會覆蓋這裡的修改。")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("儲存") { commit() }
                    .buttonStyle(.borderedProminent)
                Button("取消") { isEditing = false }
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
            // A blank row is how you abandon a "新增" you thought better of.
            if id.isEmpty && row.shares.isEmpty && row.avgCost.isEmpty { continue }
            guard !id.isEmpty else { problem = "有一列缺少代號"; return }
            guard TWSymbol(id) != nil else {
                problem = "無法辨識代號 \(id)（上櫃請寫 TPEX-3491）"; return
            }
            guard let shares = Double(row.shares.trimmingCharacters(in: .whitespaces)),
                  shares >= 0 else {
                problem = "\(id) 的股數不是數字"; return
            }
            guard let cost = Double(row.avgCost.trimmingCharacters(in: .whitespaces)),
                  cost >= 0 else {
                problem = "\(id) 的均價不是數字"; return
            }
            guard !positions.contains(where: { $0.stockId == id }) else {
                problem = "\(id) 重複"; return
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
                problem = "現金不是數字"; return
            }
            cashValue = parsed
        }

        let edited = Holdings(updatedAt: TWMarketClock.tradingDay(),
                              cash: cashValue,
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
                Label("匯入", systemImage: "square.and.arrow.down")
            }
            .help("選擇每日交易計畫 JSON")

            if !source.archives.isEmpty {
                Menu {
                    ForEach(source.archives) { archive in
                        Button("\(archive.date)　\(archive.stockCount) 檔") {
                            source.loadArchive(archive)
                        }
                    }
                } label: {
                    Label("記錄", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("載入先前的計畫")
            }

            if source.isPinned {
                Button { source.goLive() } label: {
                    Label("即時", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("回到目前監看的計畫檔")
            } else if source.displayPath != nil {
                Button { source.reload() } label: {
                    Label("重載", systemImage: "arrow.clockwise")
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
                Label("檢視 \(source.pinnedArchiveDate ?? "") 的歷史計畫 · 通知已暫停",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                // Reviewing an old plan and trading one are different intents,
                // so arming it is a deliberate second tap rather than a guess.
                Button("設為使用中") { source.activatePinned() }
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
            Label("\(date) 的計畫，非今日", systemImage: "exclamationmark.triangle.fill")
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
            Label("尚未載入交易計畫", systemImage: "doc.text.magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text("匯入每日計畫 JSON，價格觸及關卡時會推送通知。存檔後會自動重新載入。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("匯入計畫…") { source.chooseFile() }
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
                Text("交易計畫").font(.headline)
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
                Label("大盤破線 · 新倉通知已停止", systemImage: "exclamationmark.octagon.fill")
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
                    Text("大盤關卡 \(StocksFormat.price(line))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let index {
                        Text("· 現 \(StocksFormat.price(index.price))")
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
                    Text("關卡階梯 " + rungs.map(StocksFormat.price).joined(separator: " → ")
                         + "（破最後一道才停新倉）")
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
                        Text(StocksFormat.price(quote.price))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(quote.isUp ? .green : .red)
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
                Text(StocksFormat.price(quote.price))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.isUp ? .green : .red)
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

    var body: some View {
        let rungs = rungs()
        if rungs.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rungs) { rung in
                    switch rung.content {
                    case .level(let status):
                        levelRung(status)
                    case .price(let value):
                        priceRung(value)
                    }
                }
            }
        }
    }

    private func levelRung(_ status: LevelStatus) -> some View {
        HStack(spacing: 6) {
            Text(status.line.map(StocksFormat.price) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)

            Rectangle()
                .fill(StocksFormat.tint(for: status.kind).opacity(status.hasFired ? 0.9 : 0.45))
                .frame(width: 14, height: 1.5)

            Text(StocksFormat.levelLabel(status.kind))
                .font(.caption2.weight(.medium))
                .foregroundStyle(StocksFormat.tint(for: status.kind))

            if let band = status.band, band.count >= 2 {
                Text("\(StocksFormat.price(band[0]))–\(StocksFormat.price(band[band.count - 1]))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if status.hasFired {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2).foregroundStyle(.green)
            } else if status.needsHistory {
                // This level cannot fire yet. Saying so beats looking armed.
                Text("待日線")
                    .font(.caption2).foregroundStyle(.orange)
            } else if status.isSuppressedByGate {
                Image(systemName: "hand.raised.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if status.isAdvisoryOnly {
                Text("僅提示").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 18)
    }

    private func priceRung(_ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(StocksFormat.price(value))
                .font(.caption.weight(.semibold).monospacedDigit())
                .frame(width: 46, alignment: .trailing)

            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 2)

            Text("現價")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)

            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.vertical, 1)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }

    private struct Rung: Identifiable {
        enum Content { case level(LevelStatus), price(Double) }
        let id: String
        let content: Content
    }

    /// Levels high-to-low with the live price inserted where it actually sits.
    /// Levels without a resolvable line (a prose-only `reentry`) have no rung —
    /// they'd have no position on the ladder, and inventing one would misplace
    /// the price marker relative to everything else.
    private func rungs() -> [Rung] {
        var out = rows
            .filter { $0.line != nil }
            .sorted { ($0.line ?? 0) > ($1.line ?? 0) }
            .map { Rung(id: $0.id, content: .level($0)) }

        guard let price else { return out }
        let insertAt = out.firstIndex { rung in
            if case .level(let status) = rung.content { return (status.line ?? 0) < price }
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
struct StocksStockDetail: View {
    let stock: StrategyPlan.StockPlan
    let rows: [LevelStatus]
    let quote: StockQuote?
    let alerts: [StrategyAlert]
    var showsLadder = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsLadder {
                header
                StocksLevelLadder(rows: rows, price: quote?.price)
            }

            if !alerts.isEmpty {
                detailGroup("今日通知") {
                    ForEach(alerts) { alert in
                        HStack(alignment: .top, spacing: 6) {
                            Text(StocksFormat.time(alert.firedAt))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            // An approach warning and a real trigger must never
                            // look alike in a list you scan in a hurry.
                            if let band = alert.approachBand {
                                Text("接近\(StocksFormat.levelLabel(alert.levelKind)) "
                                     + StocksFormat.price(band)
                                     + (alert.approachBandIsTWD ? " 元" : "%"))
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            } else {
                                Text("\(StocksFormat.levelLabel(alert.levelKind)) \(StocksFormat.price(alert.price))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(StocksFormat.tint(for: alert.levelKind))
                            }
                        }
                    }
                }
            }

            // The prose is the part you actually act on, so each level gets its
            // condition in full rather than truncated to a number.
            detailGroup("關卡條件") {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(StocksFormat.levelLabel(row.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(StocksFormat.tint(for: row.kind))
                            if let line = row.line {
                                Text(StocksFormat.price(line))
                                    .font(.caption.monospacedDigit())
                            }
                            // The quantity is the actionable half of a level and
                            // gets weight to match — not a grey footnote.
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
                                Text("≈ \(shares) 股")
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
                            Text("現金僅夠 \(affordable) 股")
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
                detailGroup("目標") {
                    HStack(spacing: 5) {
                        Text("\(StocksFormat.price(band[0]))–\(StocksFormat.price(band[band.count - 1]))")
                            .font(.caption.weight(.semibold).monospacedDigit())
                        if let quote, band[0] > 0 {
                            Text("還有 \(StocksFormat.signedPercent((band[0] - quote.price) / quote.price * 100))")
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
                detailGroup("部位階梯") {
                    if let up = path.up, !up.isEmpty {
                        Text("加：\(up.joined(separator: " → "))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                    }
                    if let down = path.down, !down.isEmpty {
                        Text("減：\(down.joined(separator: " → "))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.red)
                    }
                    if let max = path.max {
                        Text("上限 \(max)").font(.caption2.weight(.medium))
                    }
                    if let note = path.note {
                        Text(note).font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let watch = stock.watchToday, !watch.isEmpty {
                detailGroup("今日觀察") {
                    ForEach(Array(watch.enumerated()), id: \.offset) { _, item in
                        Label(item, systemImage: "circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(BulletLabelStyle())
                    }
                }
            }

            if let events = stock.events, !events.isEmpty {
                detailGroup("事件") {
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
                detailGroup("依據") {
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
                Text("\(score)分").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let quote {
                Text(StocksFormat.signedPercent(quote.changePercent))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quote.isUp ? .green : .red)
            }
        }
    }

    private func eventLabel(_ event: StrategyPlan.PlanEvent) -> String {
        let name: String
        switch event.type {
        case "ex_dividend": name = "除息"
        case "monthly_revenue": name = "月營收"
        case "fomc": name = "FOMC"
        default: name = event.type ?? "事件"
        }
        guard let value = event.value else { return name }
        return "\(name) \(StocksFormat.price(value))"
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
