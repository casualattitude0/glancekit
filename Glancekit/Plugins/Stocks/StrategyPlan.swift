import Foundation

/// A day's trading plan, as generated from the morning warm-up report.
///
/// The governing constraint on this model: **an existing plan file must decode
/// unchanged.** The plan is written for a human first — its `condition` fields
/// are prose ("收盤突破且量≥2602張(20日均量1.5x)；或回踩1300–1355縮量承接"),
/// and no parser is going to do that justice. So the split is deliberate:
///
/// - The machine decides *when to interrupt you*, from the numbers it can read.
/// - The prose rides along in the notification, and you decide *what to do*.
///
/// An optional `trigger` object per level sharpens the first half without
/// touching the second. Where it's absent, the level still works — inferred
/// from the level's own name and price. See `PLAN_SCHEMA.md`.
struct StrategyPlan: Codable, Equatable {
    var date: String?
    var generatedFrom: String?
    var market: MarketView?
    var plans: [StockPlan]

    enum CodingKeys: String, CodingKey {
        case date, generatedFrom, market, plans
        // holding-plan.json spelling
        case positions, marketGate, basedOn
    }

    init(date: String?, generatedFrom: String?, market: MarketView?, plans: [StockPlan]) {
        self.date = date
        self.generatedFrom = generatedFrom
        self.market = market
        self.plans = plans
    }

    /// Decodes `plan.json` and `holding-plan.json` alike.
    ///
    /// The two files carry the same levels in different wrappers: the plan lists
    /// `plans[]`, while the holding plan lists `positions[]` each with the day's
    /// plan embedded under `plan`. Accepting both means whichever file you reach
    /// for imports and works, instead of failing with a decoder error about a
    /// key you never wrote.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try? c.decodeIfPresent(String.self, forKey: .date)
        generatedFrom = (try? c.decodeIfPresent(String.self, forKey: .generatedFrom))
            ?? (try? c.decodeIfPresent(String.self, forKey: .basedOn)) ?? nil

        if let direct = try? c.decodeIfPresent([StockPlan].self, forKey: .plans), !direct.isEmpty {
            plans = direct
            market = try? c.decodeIfPresent(MarketView.self, forKey: .market)
            return
        }

        // holding-plan.json shape.
        let positions = (try? c.decodeIfPresent([HoldingPlanPosition].self, forKey: .positions)) ?? []
        // `not_covered` entries carry an empty `levels` stub; they're holdings,
        // not plans, and padding the board with them would say otherwise.
        plans = positions.compactMap(\.asStockPlan)

        if var view = try? c.decodeIfPresent(MarketView.self, forKey: .market) {
            if view.gate == nil { view.gate = try? c.decodeIfPresent(Gate.self, forKey: .marketGate) }
            market = view
        } else if let gate = try? c.decodeIfPresent(Gate.self, forKey: .marketGate) {
            market = MarketView(gate: gate)
        } else {
            market = nil
        }
    }

    /// Always writes the canonical `plan.json` shape; the holding-plan keys are
    /// decode-only aliases.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(generatedFrom, forKey: .generatedFrom)
        try c.encodeIfPresent(market, forKey: .market)
        try c.encode(plans, forKey: .plans)
    }

    struct MarketView: Codable, Equatable {
        var structure: String? = nil
        var shortTerm: String? = nil
        var usBackdrop: String? = nil
        var verdict: String? = nil
        var gate: Gate? = nil
        var usWatch: ExternalWatch? = nil
        var events: [PlanEvent]? = nil
    }

    /// The index-level kill switch.
    ///
    /// `ladder` is a staircase of rungs, not a single line: losing the first is
    /// a warning, losing the last is what actually stops new positions. Reading
    /// only the first rung would freeze the whole plan at the first wobble —
    /// so suppression deliberately keys off the *lowest* rung, and each rung
    /// gets its own notification on the way down.
    struct Gate: Codable, Equatable {
        var line: Double?
        var ladder: [Double]?
        var source: String?
        var rule: String?
        var reclaimLine: ReclaimLine?

        /// Rungs high to low, falling back to the single `line`.
        var rungs: [Double] {
            let all = ladder ?? [line].compactMap { $0 }
            return all.sorted(by: >)
        }

        /// The rung that actually suppresses new positions.
        var suppressionLine: Double? { rungs.last }
    }

    struct ReclaimLine: Codable, Equatable {
        var price: Double?
        var source: String?
        var note: String?
    }

    /// An external market the plan watches but this glance doesn't quote (the
    /// Nasdaq gap). Displayed, never evaluated — inventing a verdict about an
    /// index we have no price for would be worse than showing the note.
    struct ExternalWatch: Codable, Equatable {
        var note: String?
        var trigger: PlanTrigger?
    }

    /// Where a position is allowed to go, and the rungs it steps through.
    struct PositionPath: Codable, Equatable {
        var max: String?
        var up: [String]?
        var down: [String]?
        var note: String?
    }

    /// The price band at which the plan says to stop and reassess.
    struct Target: Codable, Equatable {
        var band: [Double]?
        var source: String?
    }

    struct PlanEvent: Codable, Equatable {
        var type: String?
        var date: String?
        var value: Double?
        var note: String?
    }

    struct Evidence: Codable, Equatable {
        var item: String?
        var value: String?
    }

    struct StockPlan: Codable, Equatable {
        var stockId: String
        var name: String?
        var flag: String?
        var score: Int?
        var evidence: [Evidence]?
        /// Keyed by level kind — `entry`, `add`, `trim`, `cut`, `reentry`.
        /// A dictionary rather than fixed fields so a plan can introduce a new
        /// kind without this decoder rejecting the whole file.
        var levels: [String: PlanLevel]?
        var events: [PlanEvent]?
        var watchToday: [String]?
        var review: String?
        var target: Target?
        var positionPath: PositionPath?

        var symbol: MarketSymbol? { MarketSymbol(stockId) }
        var displayName: String { name ?? stockId }
    }

    /// The symbols a plan wants quoted, in file order.
    var symbols: [MarketSymbol] { plans.compactMap(\.symbol) }

    /// Canonical display order for levels, from most bullish to most bearish;
    /// anything unrecognized sorts last.
    ///
    /// `reduce` sits between `trim` and `cut` — the plan's own escalation is
    /// 釋出警戒 → 減倉警戒 → 全數出倉警戒, and showing them out of that order
    /// would misrepresent how bad things have got.
    static let levelOrder = ["entry", "add", "trim", "reduce", "cut", "reentry"]
}

/// One entry of `holding-plan.json`'s `positions[]` — a holding with the day's
/// plan for it attached.
struct HoldingPlanPosition: Decodable {
    var stockId: String
    var name: String?
    var status: String?
    var plan: EmbeddedPlan?

    struct EmbeddedPlan: Decodable {
        var flag: String?
        var score: Int?
        var levels: [String: PlanLevel]?
        var positionPath: StrategyPlan.PositionPath?
        var target: StrategyPlan.Target?
        var events: [StrategyPlan.PlanEvent]?
        var watchToday: [String]?
        var evidence: [StrategyPlan.Evidence]?
    }

    /// Nil for a position with no real plan — `not_covered` stubs carry an empty
    /// `levels`, and a plan with no levels can neither fire nor be read.
    var asStockPlan: StrategyPlan.StockPlan? {
        guard let plan, let levels = plan.levels, !levels.isEmpty else { return nil }
        return StrategyPlan.StockPlan(
            stockId: stockId, name: name, flag: plan.flag, score: plan.score,
            evidence: plan.evidence, levels: levels, events: plan.events,
            watchToday: plan.watchToday, review: nil,
            target: plan.target, positionPath: plan.positionPath)
    }
}

/// How much to trade at a level, and where that leaves the position.
///
/// The whole point of an alert is to tell you what to *do*, and "進場 1355" on
/// its own doesn't: a third of a position and the whole thing are very
/// different instructions. So this rides in the notification title.
struct PositionChange: Codable, Equatable {
    /// What to execute, verbatim from the plan — "+1/3", "sell 1/2 of holdings",
    /// "sell all". Never paraphrased: a mis-glossed trade instruction is a much
    /// worse failure than an untranslated one.
    var action: String?
    /// The resulting position, e.g. "1/3", "0", "原水位".
    var after: String?

    enum CodingKeys: String, CodingKey { case action, after }

    init(action: String?, after: String? = nil) {
        self.action = action
        self.after = after
    }

    /// Accepts the object form and the string shorthand the schema allows.
    ///
    /// `"+1/3→2/3"` splits into action and resulting level. A *bare* string
    /// (`"1/3"`, the pre-v7 spelling) is deliberately read as the **resulting
    /// level only**, never as an instruction: "1/3" on an entry meant "add a
    /// third" while "1/2" on a trim meant "sell half", and guessing wrong would
    /// put a fabricated share count in front of a trade. Better to convert
    /// nothing than to convert it backwards.
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            let separators = CharacterSet(charactersIn: "→⇒")
            var text = single.replacingOccurrences(of: "->", with: "→")
            text = text.replacingOccurrences(of: "=>", with: "⇒")
            let parts = text.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count >= 2 {
                action = parts[0]
                after = parts[1]
            } else {
                action = nil
                after = single.trimmingCharacters(in: .whitespaces)
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        after = try c.decodeIfPresent(String.self, forKey: .after)
    }

    /// One line for a notification or a row: "+1/3 → 1/3".
    var summary: String? {
        switch (action, after) {
        case let (a?, b?): return "\(a) → \(b)"
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

// MARK: - Levels

struct PlanLevel: Codable, Equatable {
    /// A single price, or the low end of a band. Absent for a level defined
    /// purely by prose (`reentry` usually is).
    var price: Double?
    /// The full band when `price` was written as an array, e.g. `[1348, 1355]`.
    var band: [Double]?
    var condition: String?
    var size: PositionChange?
    var source: String?
    /// Optional machine-readable sharpening. Absent → inferred, see `ResolvedTrigger`.
    var trigger: PlanTrigger?

    enum CodingKeys: String, CodingKey { case price, condition, size, source, trigger }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        condition = try c.decodeIfPresent(String.self, forKey: .condition)
        size = try c.decodeIfPresent(PositionChange.self, forKey: .size)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        trigger = try c.decodeIfPresent(PlanTrigger.self, forKey: .trigger)

        // `price` is a scalar for most levels but an array for a retest band
        // (`"add": {"price": [1348, 1355]}`). Both spellings are in real plans,
        // so both decode; the band's low end becomes the scalar so a level
        // always has one number to compare against.
        if let single = try? c.decodeIfPresent(Double.self, forKey: .price) {
            price = single
            band = nil
        } else if let many = try? c.decodeIfPresent([Double].self, forKey: .price), !many.isEmpty {
            band = many.sorted()
            price = band?.first
        } else {
            price = nil
            band = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let band { try c.encode(band, forKey: .price) }
        else { try c.encodeIfPresent(price, forKey: .price) }
        try c.encodeIfPresent(condition, forKey: .condition)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(trigger, forKey: .trigger)
    }
}

// MARK: - Triggers

enum TriggerOp: String, Codable {
    /// Price rises through the line (armed from below).
    case crossAbove
    /// Price falls through the line (armed from above).
    case crossBelow
    /// Price enters a retest band from outside it.
    case enterBand
    /// Price closed back above a line within N sessions of breaking it —
    /// the plan's 「破X後3日內收回」 rule.
    case reclaimWithinDays
    /// Price broke a line and has stayed below it for N sessions — the other
    /// half of the same rule, the one that turns a wobble into an exit.
    case breakdownHeldDays
}

/// What the trigger's price is measured against. `ma20`/`ma60` track the
/// *computed* average from `TWSEHistoryStore` rather than a literal, so a plan
/// that's a few days old doesn't quietly judge you against a moving average
/// that has since moved.
enum PriceReference: String, Codable {
    case literal
    case ma5, ma10, ma20, ma40, ma60, ma120, ma240

    var days: Int? {
        switch self {
        case .literal: return nil
        case .ma5: return 5
        case .ma10: return 10
        case .ma20: return 20
        case .ma40: return 40
        case .ma60: return 60
        case .ma120: return 120
        case .ma240: return 240
        }
    }

    /// Unknown values degrade to `.literal` instead of throwing.
    ///
    /// `ref` is an open vocabulary on the generator's side — the schema already
    /// lists ma5/ma40/ma240, and it will grow. A strict enum turns one
    /// unrecognised string into a `typeMismatch` that fails the **entire plan
    /// file**, so a new moving average nobody told this app about would take
    /// every alert down with it. Falling back to the literal price the schema
    /// requires alongside `ref` keeps the level working.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PriceReference(rawValue: raw.lowercased()) ?? .literal
    }
}

struct VolumeCondition: Codable, Equatable {
    /// Absolute floor in 張.
    var min: Double?
    /// Absolute ceiling in 張 — how 量縮 is expressed.
    var max: Double?
    /// Floor as a multiple of the N-session average (e.g. 1.5).
    var multiple: Double?
    /// Ceiling as a multiple of the N-session average (e.g. 0.8 for 量縮).
    var maxMultiple: Double?
    /// Sessions in the average; defaults to 20.
    var refAvgDays: Int?
}

struct PlanTrigger: Codable, Equatable {
    var op: TriggerOp?
    var price: Double?
    var band: [Double]?
    var ref: PriceReference?
    /// Only evaluate at the close. Defaults to whether the prose says 收盤.
    var onClose: Bool?
    var volumeLots: VolumeCondition?
    /// Session count for the multi-day ops.
    var confirmWithinDays: Int?
    /// How near the line, **in TWD**, earns an early heads-up — one alert per
    /// band as the price closes in, e.g. `[10, 5, 2]` = 10元/5元/2元 away.
    ///
    /// Absolute rather than percentage because that is what the plan schema
    /// specifies, and because the plan author is choosing these per level: a
    /// 2元 warning on a 1195 stop is a deliberately tight "this is happening",
    /// which "2%" (24元) would not be. Omit to fall back on the glance-wide
    /// percentage bands; give `[]` to silence this level alone.
    var approachBands: [Double]?
}

/// A trigger with every gap filled in — from the explicit `trigger` where the
/// plan supplied one, and inferred from the level otherwise. This is the only
/// thing `StrategyEngine` evaluates, so inference and explicit configuration
/// meet in one shape and the engine never has to know which it got.
struct ResolvedTrigger: Equatable {
    var kind: String            // level name: entry / add / trim / cut / …
    var op: TriggerOp
    var reference: PriceReference
    var price: Double?
    var band: [Double]?
    var onClose: Bool
    var volume: VolumeCondition?
    var confirmWithinDays: Int
    /// Per-level approach distances **in TWD**; nil means fall back to the
    /// glance-wide percentage bands.
    var approachBands: [Double]?
    /// True when nothing in the level was machine-readable enough to evaluate.
    /// Such a level is still *displayed*, it just never fires by itself.
    var isAdvisoryOnly: Bool

    /// Levels that open or grow a position — the ones the market gate suppresses.
    var opensPosition: Bool { kind == "entry" || kind == "add" || kind == "reentry" }
}

enum TriggerResolver {
    /// 「量≥2602張」 / 「量>= 2,602 張」 — the one volume phrasing the plans use
    /// consistently enough to read mechanically. Anything looser (量縮, 帶量)
    /// needs a baseline and is left to an explicit `volumeLots`.
    private static let volumeRegex = try? NSRegularExpression(
        pattern: "量\\s*[≥>=]+\\s*([0-9,]+)\\s*張")

    static func resolve(kind: String, level: PlanLevel) -> ResolvedTrigger {
        let prose = level.condition ?? ""
        let t = level.trigger

        // Default direction comes from what the level *is*: entry and add are
        // things you do on the way up, trim and cut on the way down.
        //
        // A level written as a *range* (`"price": [1348, 1355]`) is a different
        // animal — it's a retest zone, "come back into here", not a line to
        // punch through. Treating its low end as a crossing line is what made
        // 昇達科's `add` fire on the same rally that triggered `entry`, which is
        // precisely the double-alert the plan means to avoid: you add on the
        // pullback, not on the breakout.
        let defaultOp: TriggerOp? = {
            if level.band != nil { return .enterBand }
            switch kind {
            case "entry", "add": return .crossAbove
            case "trim", "cut": return .crossBelow
            default: return nil          // reentry is prose-shaped; needs an explicit op
            }
        }()

        let op = t?.op ?? defaultOp ?? .crossAbove
        let band = t?.band ?? level.band
        let price = t?.price ?? level.price
        let reference = t?.ref ?? .literal

        // A literal-referenced trigger with no number can't be evaluated; a
        // ma20/ma60-referenced one supplies its own number later.
        let evaluable = (reference != .literal)
            || price != nil
            || (band?.isEmpty == false && op == .enterBand)
            || (t?.op != nil && (op == .reclaimWithinDays || op == .breakdownHeldDays))
        let hasExplicitOp = t?.op != nil
        let isAdvisoryOnly = !evaluable || (defaultOp == nil && !hasExplicitOp)

        return ResolvedTrigger(
            kind: kind,
            op: op,
            reference: reference,
            price: price,
            band: band,
            // 收盤 / "on close" in the prose means "on the close, not on a
            // wick" — honouring it is what stops an intraday spike through a
            // stop from firing an alert the plan never intended. Both spellings
            // are read, so a plan written in either language behaves the same.
            onClose: t?.onClose ?? prose.contains("收盤")
                || prose.lowercased().contains("on close")
                || prose.lowercased().contains("at the close"),
            volume: t?.volumeLots ?? inferredVolume(from: prose),
            confirmWithinDays: t?.confirmWithinDays ?? 3,
            approachBands: t?.approachBands,
            isAdvisoryOnly: isAdvisoryOnly
        )
    }

    private static func inferredVolume(from prose: String) -> VolumeCondition? {
        guard let regex = volumeRegex else { return nil }
        let ns = prose as NSString
        guard let match = regex.firstMatch(in: prose, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let digits = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "")
        guard let lots = Double(digits) else { return nil }
        return VolumeCondition(min: lots, max: nil, multiple: nil, maxMultiple: nil, refAvgDays: nil)
    }
}
