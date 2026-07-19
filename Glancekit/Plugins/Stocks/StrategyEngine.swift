import Foundation
import Observation

/// One fired alert, kept for the popover's recent-alerts list as well as for
/// the notification itself.
struct StrategyAlert: Identifiable, Equatable {
    let id: String              // also the dedupe key
    let symbol: TWSymbol
    let stockName: String
    let levelKind: String
    let title: String
    let body: String
    let price: Double
    let firedAt: Date
    /// True for an early "closing in on this line" warning rather than the
    /// level actually being reached. Kept distinct so a heads-up can never be
    /// mistaken for — or outrank — the real thing.
    var isApproach: Bool = false
    /// The band that fired, for an approach alert.
    var approachBand: Double? = nil
    /// True when `approachBand` is a TWD distance rather than a percentage.
    var approachBandIsTWD: Bool = false
}

/// The live status of one level, for display. The popover shows these whether
/// or not they can fire, so an advisory-only level is still visible rather than
/// silently missing.
struct LevelStatus: Identifiable, Equatable {
    let id: String
    let kind: String
    let line: Double?
    let distancePercent: Double?
    let hasFired: Bool
    let isAdvisoryOnly: Bool
    let isSuppressedByGate: Bool
    let condition: String?
    let size: PositionChange?
    let source: String?
    /// The full retest band, when the level was written as a range.
    let band: [Double]?
    /// True when this level needs daily bars it doesn't have yet — a relative
    /// volume condition with no 20-day average, or an ma20/ma60 reference.
    ///
    /// Surfaced because the safe behaviour (treat an unmeasurable condition as
    /// unmet) is also a *silent* one: without this the level looks armed and
    /// simply never fires, which is the worst way for an alerting tool to fail.
    let needsHistory: Bool
    /// The level's size expressed in actual shares, when derivable.
    let instruction: ShareInstruction?
}

/// Evaluates a `StrategyPlan` against live quotes and decides when to interrupt.
///
/// Three rules shape everything here, and all three exist to keep the alert
/// stream trustworthy — an alerting tool that cries wolf gets muted, and a
/// muted tool is worse than none:
///
/// 1. **Seed before firing.** The first tick after a plan loads only records
///    prices. Otherwise launching the app mid-session would immediately fire
///    every `cut` whose line is already below the current price, none of which
///    are news.
/// 2. **A level fires once per day.** Prices oscillate around a line; without
///    dedupe a stock hovering at its entry would notify every 20 seconds.
/// 3. **收盤 means 收盤.** A condition written for the close isn't evaluated on
///    an intraday wick through it.
@MainActor
@Observable
final class StrategyEngine {

    private let firedKey = "glancekit.stocks.firedAlerts"
    private let firedDateKey = "glancekit.stocks.firedPlanDate"

    /// Previous tick's price per symbol. Absent means "not yet seeded".
    private var lastPrice: [TWSymbol: Double] = [:]
    /// Dedupe keys already fired for the current plan date.
    private var fired: Set<String> = []
    /// The plan date the `fired` set belongs to.
    private var firedPlanDate: String?

    /// The live portfolio, so an alert can say how many shares to trade rather
    /// than what fraction of an abstract position.
    var holdings: Holdings?

    private(set) var gateBreached = false
    private(set) var recentAlerts: [StrategyAlert] = []
    /// Per-symbol level display state, rebuilt each tick for the popover.
    private(set) var statuses: [String: [LevelStatus]] = [:]

    private let history: TWSEHistoryStore
    private let defaults: UserDefaults

    /// Distances from a level, in percent, that each earn one early warning as
    /// the price closes in — widest first is how they're consumed.
    ///
    /// Defaults to 10/5/2: far enough out to go and look at something, then a
    /// genuine "this is about to happen". More bands than that turns a useful
    /// heads-up into the thing you mute.
    private(set) var approachBands: [Double]

    static let approachBandsKey = "glancekit.stocks.approachBands"
    static let defaultApproachBands: [Double] = [10, 5, 2]

    init(history: TWSEHistoryStore = .shared, defaults: UserDefaults = .standard) {
        self.history = history
        self.defaults = defaults
        fired = Set(defaults.stringArray(forKey: firedKey) ?? [])
        firedPlanDate = defaults.string(forKey: firedDateKey)
        let stored = (defaults.array(forKey: Self.approachBandsKey) as? [Double]) ?? []
        approachBands = stored.isEmpty ? Self.defaultApproachBands : Self.normalize(stored)
    }

    /// Replace the approach bands. Values are de-duplicated, clamped to a sane
    /// range and sorted; an empty list switches approach warnings off.
    func setApproachBands(_ bands: [Double]) {
        approachBands = Self.normalize(bands)
        defaults.set(approachBands, forKey: Self.approachBandsKey)
    }

    private static func normalize(_ bands: [Double]) -> [Double] {
        Array(Set(bands.filter { $0 > 0 && $0 <= 100 })).sorted(by: >)
    }

    /// Drops all seeded prices — called when a new plan is loaded, so the next
    /// tick re-seeds rather than comparing against prices from the old plan.
    func reseed() {
        lastPrice.removeAll()
    }

    /// Evaluate one tick. Returns the alerts that fired (already deduped);
    /// the caller is responsible for delivering them.
    func evaluate(plan: StrategyPlan,
                  quotes: [TWSymbol: StockQuote],
                  now: Date = Date()) async -> [StrategyAlert] {

        rollOverIfNeeded(planDate: plan.date)

        var alerts: [StrategyAlert] = []
        let atClose = TWMarketClock.isCloseWindow(now) || TWMarketClock.isAfterClose(now)

        // MARK: Market gate
        //
        // The plan's rule is written as 收盤失守, but suppression and
        // notification are treated differently on purpose: we stop *arming new
        // positions* the moment the index trades below the line (the cautious
        // direction — the worst case is a missed entry), while only *notifying*
        // about the breach once it's a real close (the accurate direction —
        // nobody needs a banner for a wick).
        if let gate = plan.market?.gate, let taiex = quotes[.taiex], !gate.rungs.isEmpty {
            // Only the LAST rung stops new positions; the ones above it are
            // warnings. Suppressing at the first rung would freeze the plan on
            // a wobble the plan itself treats as survivable.
            gateBreached = gate.suppressionLine.map { taiex.price < $0 } ?? false

            if atClose {
                for (index, rung) in gate.rungs.enumerated() where taiex.price < rung {
                    let key = "gate|\(plan.date ?? "-")|\(fmt(rung))"
                    guard !fired.contains(key) else { continue }
                    fired.insert(key)
                    let isFinal = index == gate.rungs.count - 1
                    alerts.append(StrategyAlert(
                        id: key, symbol: .taiex, stockName: "加權指數", levelKind: "gate",
                        title: "大盤跌破 \(fmt(rung))　現 \(fmt(taiex.price))"
                            + (isFinal ? " · 新倉停止" : ""),
                        body: [
                            isFinal ? "新倉 entry / add / reentry 通知已停止。"
                                    : "第 \(index + 1)/\(gate.rungs.count) 道關卡，新倉尚未停止。",
                            gate.source.map { "依據：\($0)" },
                            gate.rule
                        ].compactMap { $0 }.joined(separator: "\n"),
                        price: taiex.price, firedAt: now))
                }
            }
        } else {
            gateBreached = false
        }

        // MARK: Per-stock levels

        var newStatuses: [String: [LevelStatus]] = [:]

        for stock in plan.plans {
            guard let symbol = stock.symbol, let quote = quotes[symbol] else { continue }
            let previous = lastPrice[symbol]
            let levels = stock.levels ?? [:]

            // Resolved once per stock so the exit ladder can cascade.
            let instructions = ShareMath.instructions(
                levels: levels,
                order: orderedKinds(of: levels),
                holding: holdings?.position(for: symbol),
                price: quote.price,
                cash: holdings?.cash)

            var rows: [LevelStatus] = []
            for kind in orderedKinds(of: levels) {
                guard let level = levels[kind] else { continue }
                let trigger = TriggerResolver.resolve(kind: kind, level: level)
                let line = await resolveLine(trigger, symbol: symbol)
                let needsHistory = await isMissingHistory(trigger, symbol: symbol)
                let key = dedupeKey(plan: plan, stock: stock, kind: kind, op: trigger.op)
                let suppressed = gateBreached && trigger.opensPosition

                rows.append(LevelStatus(
                    id: "\(stock.stockId)|\(kind)",
                    kind: kind,
                    line: line,
                    distancePercent: line.map { $0 == 0 ? 0 : (quote.price - $0) / $0 * 100 },
                    hasFired: fired.contains(key),
                    isAdvisoryOnly: trigger.isAdvisoryOnly,
                    isSuppressedByGate: suppressed,
                    condition: level.condition,
                    size: level.size,
                    source: level.source,
                    band: trigger.op == .enterBand ? trigger.band : nil,
                    needsHistory: needsHistory,
                    instruction: instructions[kind]
                ))

                if trigger.isAdvisoryOnly || suppressed { continue }
                if fired.contains(key) { continue }

                // Approach warnings come first and are deliberately NOT gated on
                // `onClose`: the point of "you're 2% from the stop" is to reach
                // you while you can still do something, which is exactly the
                // intraday window a 收盤 condition itself stays silent through.
                if previous != nil,
                   let approach = approachAlert(trigger, line: line, stock: stock,
                                                symbol: symbol, quote: quote,
                                                plan: plan, now: now) {
                    alerts.append(approach)
                }

                if trigger.onClose && !atClose { continue }
                // Rule 1: seeded symbols only. A symbol we've never seen a
                // previous price for can't have *crossed* anything yet.
                guard previous != nil else { continue }

                let didTrigger = await matches(trigger, line: line, symbol: symbol,
                                               quote: quote, previous: previous, atClose: atClose)
                guard didTrigger else { continue }
                guard await volumeSatisfied(trigger, symbol: symbol, quote: quote) else { continue }

                fired.insert(key)
                alerts.append(makeAlert(key: key, symbol: symbol, stock: stock, kind: kind,
                                        level: level, line: line, quote: quote,
                                        instruction: instructions[kind], now: now))
            }
            newStatuses[stock.stockId] = rows
        }

        // Seed/refresh last-seen prices for every quoted symbol, including ones
        // this plan doesn't mention — cheap, and correct if the plan gains them.
        for (symbol, quote) in quotes { lastPrice[symbol] = quote.price }

        statuses = newStatuses
        if !alerts.isEmpty {
            persistFired()
            recentAlerts = (alerts + recentAlerts).prefix(20).map { $0 }
        }
        return alerts
    }

    // MARK: - Trigger evaluation

    /// The number this trigger compares against — a literal from the plan, or a
    /// moving average recomputed from daily bars.
    private func resolveLine(_ trigger: ResolvedTrigger, symbol: TWSymbol) async -> Double? {
        // The plan's own number wins whenever it is present, including on a
        // `ref: ma20` trigger.
        //
        // This is the schema's rule — "用 ref 時仍必須同時附數字 price" — and it
        // is the right one: the number in the plan is the number in the morning
        // report you actually read, so an alert that fired off a value this app
        // recomputed could disagree with the document it came from. Recomputing
        // stays as the fallback for a plan that omits the number.
        if let literal = trigger.price { return literal }
        guard let days = trigger.reference.days else { return nil }
        return await history.movingAverage(days, for: symbol)
    }

    private func matches(_ trigger: ResolvedTrigger,
                         line: Double?,
                         symbol: TWSymbol,
                         quote: StockQuote,
                         previous: Double?,
                         atClose: Bool) async -> Bool {
        let price = quote.price
        switch trigger.op {
        case .crossAbove:
            guard let line, let previous else { return false }
            return previous < line && price >= line
        case .crossBelow:
            guard let line, let previous else { return false }
            return previous > line && price <= line
        case .enterBand:
            guard let band = trigger.band, band.count >= 2, let previous else { return false }
            let lo = band[0], hi = band[band.count - 1]
            let wasOutside = previous < lo || previous > hi
            return wasOutside && price >= lo && price <= hi

        // The multi-day ops are the reason daily history is fetched at all.
        // They only make sense against a settled close, so they're gated on it.
        case .reclaimWithinDays:
            guard let line, atClose else { return false }
            let closes = await closesIncludingToday(symbol: symbol, todayPrice: price)
            guard closes.count >= 2, let today = closes.last, today >= line else { return false }
            let window = closes.dropLast().suffix(trigger.confirmWithinDays)
            return window.contains { $0 < line }

        case .breakdownHeldDays:
            guard let line, atClose else { return false }
            let n = trigger.confirmWithinDays
            let closes = await closesIncludingToday(symbol: symbol, todayPrice: price)
            guard closes.count >= n + 1 else { return false }
            let held = closes.suffix(n)
            // Every session since the break is below the line, and the session
            // immediately before the run was above it — so this is the day the
            // break became a fact, not the fourth day of an old one.
            let before = closes[closes.count - n - 1]
            return held.allSatisfy { $0 < line } && before >= line
        }
    }

    /// Daily closes with today's price appended when the exchange hasn't
    /// published today's bar yet (the sweep runs at 14:00; the close window
    /// starts at 13:25).
    private func closesIncludingToday(symbol: TWSymbol, todayPrice: Double) async -> [Double] {
        let bars = await history.recentBars(20, for: symbol)
        let today = TWMarketClock.tradingDay()
        var closes = bars.map(\.close)
        if bars.last?.date != today { closes.append(todayPrice) }
        return closes
    }

    private func volumeSatisfied(_ trigger: ResolvedTrigger,
                                 symbol: TWSymbol,
                                 quote: StockQuote) async -> Bool {
        guard let condition = trigger.volume else { return true }
        // A volume condition we can't measure must not silently pass — that
        // would turn 「突破且量≥2602張」 into a bare breakout alert. But it must
        // not silently block either, so the requirement is dropped only when
        // the *whole* condition is unmeasurable.
        guard let lots = quote.volumeLots else { return false }

        if let min = condition.min, lots < min { return false }
        if let max = condition.max, lots > max { return false }

        if condition.multiple != nil || condition.maxMultiple != nil {
            let days = condition.refAvgDays ?? 20
            guard let average = await history.averageVolumeLots(days, for: symbol) else {
                // No baseline yet (first run, or a newly added symbol). Treat a
                // relative condition as unmet rather than met.
                return false
            }
            if let multiple = condition.multiple, lots < average * multiple { return false }
            if let maxMultiple = condition.maxMultiple, lots > average * maxMultiple { return false }
        }
        return true
    }

    /// Whether this trigger depends on daily bars we haven't loaded yet.
    ///
    /// Strictly "cannot fire", not merely "uses history": a `ref: ma20` level
    /// that also carries a literal price still fires off that literal, and
    /// labelling it as blocked would be its own kind of lie.
    private func isMissingHistory(_ trigger: ResolvedTrigger, symbol: TWSymbol) async -> Bool {
        if let days = trigger.reference.days, trigger.price == nil,
           await history.movingAverage(days, for: symbol) == nil { return true }
        if let v = trigger.volume, v.multiple != nil || v.maxMultiple != nil {
            let days = v.refAvgDays ?? 20
            if await history.averageVolumeLots(days, for: symbol) == nil { return true }
        }
        return false
    }

    // MARK: - Approach warnings

    /// An early heads-up when price closes to within a band of a level.
    ///
    /// Two things make this useful rather than noisy:
    ///
    /// **Direction.** Distance is measured on the side the level can actually be
    /// reached from — below an entry, above a stop. Being 5% *above* an entry
    /// isn't approaching it, it's already through it, and warning about that
    /// would fire on every level the price has left behind.
    ///
    /// **Consumption.** Firing a band also consumes every wider one, so a gap
    /// straight from 12% to 1.5% away sends a single "2%" warning rather than
    /// 10%, 5% and 2% at once. Combined with the one-per-day dedupe, a price
    /// oscillating across a boundary can't chatter.
    private func approachAlert(_ trigger: ResolvedTrigger,
                               line: Double?,
                               stock: StrategyPlan.StockPlan,
                               symbol: TWSymbol,
                               quote: StockQuote,
                               plan: StrategyPlan,
                               now: Date) -> StrategyAlert? {
        guard let line, line > 0 else { return nil }

        // Two units, never mixed: the plan states its bands in TWD (schema
        // rule), the glance-wide fallback is a percentage. Each is converted to
        // a distance in TWD here and labelled honestly in the alert, so "接近
        // 停損 2元" and "接近停損 2%" can never be mistaken for each other.
        let inTWD = trigger.approachBands != nil
        let bands = trigger.approachBands ?? approachBands.map { line * $0 / 100 }
        guard !bands.isEmpty else { return nil }

        let price = quote.price
        // Distance in TWD, measured on the side the level can be reached from.
        let distance: Double
        switch trigger.op {
        case .crossAbove, .enterBand:
            distance = line - price                     // still below the line
        case .crossBelow:
            distance = price - line                     // still above the line
        case .reclaimWithinDays, .breakdownHeldDays:
            // Multi-session outcomes, not a line the price is walking toward.
            return nil
        }
        guard distance > 0 else { return nil }

        // The tightest band the price is now inside.
        guard let band = bands.sorted().first(where: { distance <= $0 }) else { return nil }
        let unit = inTWD ? "twd" : "pct"
        let key = "approach|\(plan.date ?? "-")|\(stock.stockId)|\(trigger.kind)|\(unit)|\(Self.bandKey(band))"
        guard !fired.contains(key) else { return nil }

        // Consume this band and every wider one.
        for wider in bands where wider >= band {
            fired.insert("approach|\(plan.date ?? "-")|\(stock.stockId)|\(trigger.kind)|\(unit)|\(Self.bandKey(wider))")
        }

        let label = label(for: trigger.kind)
        return StrategyAlert(
            id: key, symbol: symbol, stockName: stock.displayName,
            levelKind: trigger.kind,
            title: "\(stock.displayName) \(symbol.code) · 接近\(label) \(fmt(line))"
                + (stock.levels?[trigger.kind]?.size?.action.map { " · \($0)" } ?? ""),
            body: [
                "距離 \(fmt(distance)) 元 / \(String(format: "%.2f", distance / line * 100))%"
                    + "（現價 \(fmt(price))）",
                stock.levels?[trigger.kind]?.size?.summary.map { summary in
                    let cascaded = ShareMath.instructions(
                        levels: stock.levels ?? [:],
                        order: orderedKinds(of: stock.levels ?? [:]),
                        holding: holdings?.position(for: symbol),
                        price: price, cash: holdings?.cash)
                    let shares = ShareMath.describe(cascaded[trigger.kind])
                    return "屆時執行：\(summary)" + (shares.map { " ≈ \($0)" } ?? "")
                },
                trigger.onClose ? "提醒：此關卡需收盤確認才會正式觸發。" : nil,
                stock.levels?[trigger.kind]?.condition
            ].compactMap { $0 }.joined(separator: "\n"),
            price: price, firedAt: now,
            isApproach: true,
            // Reported in the unit the plan chose, so the UI can say 元 or %.
            approachBand: inTWD ? band : band / line * 100,
            approachBandIsTWD: inTWD)
    }

    /// `5.0` and `5` must produce the same dedupe key, or a band would re-fire.
    private static func bandKey(_ band: Double) -> String {
        String(format: "%.4f", band)
    }

    // MARK: - Alert construction

    private func makeAlert(key: String, symbol: TWSymbol, stock: StrategyPlan.StockPlan,
                           kind: String, level: PlanLevel, line: Double?,
                           quote: StockQuote, instruction: ShareInstruction?,
                           now: Date) -> StrategyAlert {
        // The quantity goes in the *title*, because a banner shows the title
        // even when it shows nothing else — and "進場 1355" without "+1/3" is
        // an alert that tells you something happened but not what to do about
        // it, which is the one thing this whole glance exists to answer.
        var title = "\(stock.displayName) \(symbol.code) · \(label(for: kind)) \(fmt(quote.price))"
        if let action = level.size?.action { title += " · \(action)" }

        // The share count goes in the title next to the fraction: "+1/3" is the
        // plan's language, "36 股" is what you actually type into a broker.
        if let shares = instruction?.shares { title += "（\(shares) 股）" }

        var lines: [String] = []
        if let summary = level.size?.summary {
            var execution = "執行：\(summary)"
            if let detail = ShareMath.describe(instruction) { execution += " ≈ \(detail)" }
            if let max = stock.positionPath?.max { execution += "（上限 \(max)）" }
            lines.append(execution)
        }
        if let line { lines.append("觸發線 \(fmt(line))　現價 \(fmt(quote.price))") }
        if let lots = quote.volumeLots { lines.append("量 \(Int(lots)) 張") }
        // The prose is the payload — everything above is just the trigger's
        // receipt. This is the part you actually read before deciding.
        if let condition = level.condition { lines.append(condition) }
        if let source = level.source { lines.append("依據：\(source)") }
        if let note = stock.positionPath?.note { lines.append(note) }

        return StrategyAlert(id: key, symbol: symbol, stockName: stock.displayName,
                             levelKind: kind, title: title,
                             body: lines.joined(separator: "\n"),
                             price: quote.price, firedAt: now)
    }

    private func label(for kind: String) -> String {
        switch kind {
        case "entry": return "進場"
        case "add": return "加碼"
        case "trim": return "減碼"
        case "reduce": return "減倉"
        case "cut": return "停損"
        case "reentry": return "重新進場"
        default: return kind
        }
    }

    private func orderedKinds(of levels: [String: PlanLevel]) -> [String] {
        let known = StrategyPlan.levelOrder.filter { levels[$0] != nil }
        let extra = levels.keys.filter { !StrategyPlan.levelOrder.contains($0) }.sorted()
        return known + extra
    }

    private func dedupeKey(plan: StrategyPlan, stock: StrategyPlan.StockPlan,
                           kind: String, op: TriggerOp) -> String {
        "\(plan.date ?? "-")|\(stock.stockId)|\(kind)|\(op.rawValue)"
    }

    /// A new plan date wipes the fired set — that's what makes "once per day"
    /// mean per day rather than forever.
    private func rollOverIfNeeded(planDate: String?) {
        guard firedPlanDate != planDate else { return }
        firedPlanDate = planDate
        fired.removeAll()
        recentAlerts.removeAll()
        UserDefaults.standard.set(planDate, forKey: firedDateKey)
        persistFired()
    }

    private func persistFired() {
        UserDefaults.standard.set(Array(fired), forKey: firedKey)
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0f", v) : String(format: "%.2f", v)
    }
}
