import Foundation

/// The portfolio, as exported each day from the trading journal.
struct Holdings: Codable, Equatable {
    var updatedAt: String?
    /// Cash available to buy with. Nil when not tracked.
    var cash: Double?
    /// Which currency `cash` is denominated in, as an ISO code. A portfolio
    /// spanning markets holds positions in several currencies but only ever one
    /// pile of cash, so this is stated rather than inferred — guessing it from
    /// the positions would silently re-denominate the buying power the moment a
    /// foreign holding was added.
    var currency: String?
    var positions: [HoldingPosition]

    /// The market whose currency `cash` is in, for formatting and for the
    /// affordability maths. Defaults to Taiwan, which is what every existing
    /// export means by a bare `cash` field.
    var cashMarket: Market {
        guard let currency = currency?.uppercased() else { return .tw }
        return Market.allCases.first { $0.currencyCode == currency } ?? .tw
    }

    func position(for symbol: MarketSymbol) -> HoldingPosition? {
        positions.first { MarketSymbol($0.stockId) == symbol }
    }
}

struct HoldingPosition: Codable, Equatable, Identifiable {
    var stockId: String
    var name: String?
    /// Shares, not lots — these are odd-lot holdings.
    var shares: Double
    var avgCost: Double

    enum CodingKeys: String, CodingKey { case stockId, name, shares, avgCost }

    init(stockId: String, name: String?, shares: Double, avgCost: Double) {
        self.stockId = stockId
        self.name = name
        self.shares = shares
        self.avgCost = avgCost
    }

    /// `shares` and `avgCost` tolerate null and absence.
    ///
    /// A position you don't own yet is written with `"avgCost": null` — there
    /// is no average cost for shares never bought — and a strict `Double` there
    /// rejects the **entire file** over one watchlist entry. Zero is the honest
    /// value: cost basis 0, no P/L, and the profit maths already guards it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stockId = try c.decode(String.self, forKey: .stockId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        shares = (try? c.decodeIfPresent(Double.self, forKey: .shares)) ?? 0
        avgCost = (try? c.decodeIfPresent(Double.self, forKey: .avgCost)) ?? 0
    }

    var id: String { stockId }
    var symbol: MarketSymbol? { MarketSymbol(stockId) }
    /// The market this position trades in — which decides its currency and
    /// which direction its P/L is drawn in. Unparseable ids fall back to
    /// Taiwan, matching how they are already treated everywhere else.
    var market: Market { symbol?.market ?? .tw }
    var displayName: String { name ?? stockId }
    var costBasis: Double { shares * avgCost }

    func marketValue(at price: Double) -> Double { shares * price }
    func profit(at price: Double) -> Double { marketValue(at: price) - costBasis }
    func profitPercent(at price: Double) -> Double {
        costBasis == 0 ? 0 : profit(at: price) / costBasis * 100
    }
}

// MARK: - Turning a plan's fractions into share counts

/// What a level's `size.action` actually instructs.
///
/// The plan words its two sides differently on purpose, and the distinction is
/// what makes this convertible at all:
///
/// - Sells are **relative to holdings** ("sell 1/2 of holdings", "sell all"),
///   so they resolve exactly from the portfolio, whatever position you're on.
/// - Buys are **fractions of a full position** ("+1/3"), which needs a base.
enum TradeAction: Equatable {
    case addFraction(Double)
    case sellFractionOfHoldings(Double)
    case sellAll
    case buyBackToPrior
    case unrecognized

    /// `"+1/3"`, `"sell 1/2 of holdings"`, `"sell all"`, `"buy back to prior level"`.
    static func parse(_ raw: String?) -> TradeAction {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .unrecognized
        }
        let lower = raw.lowercased()
        if lower.contains("sell all") || lower.contains("出清") || lower.contains("全數出") {
            return .sellAll
        }
        if lower.contains("buy back") || lower.contains("回補") {
            return .buyBackToPrior
        }
        if let fraction = fraction(in: raw) {
            if lower.hasPrefix("+") || lower.contains("buy") || lower.contains("加") {
                return .addFraction(fraction)
            }
            if lower.hasPrefix("-") || lower.contains("sell") || lower.contains("賣") {
                return .sellFractionOfHoldings(fraction)
            }
        }
        return .unrecognized
    }

    /// First `n/m` in the string, as a value. `"1/3"` → 0.333…
    static func fraction(in s: String) -> Double? {
        guard let slash = s.firstIndex(of: "/") else { return Double(s) }
        let digits = CharacterSet(charactersIn: "0123456789.")
        let numerator = String(s[s.startIndex..<slash])
            .unicodeScalars.reversed().prefix { digits.contains($0) }
            .reversed().map(String.init).joined()
        let denominator = String(s[s.index(after: slash)...])
            .unicodeScalars.prefix { digits.contains($0) }
            .map(String.init).joined()
        guard let n = Double(numerator), let d = Double(denominator), d != 0 else { return nil }
        return n / d
    }
}

/// A level's instruction expressed in actual shares.
struct ShareInstruction: Equatable {
    /// Shares to trade. Nil when it genuinely can't be derived.
    var shares: Int?
    var isSell: Bool
    /// Shares the cash on hand can actually pay for, when that's fewer.
    var affordableShares: Int?
    /// Why there's no number, or what to watch out for.
    var note: String?

    var isShort: Bool {
        guard let shares, let affordableShares else { return false }
        return affordableShares < shares
    }
}

enum ShareMath {
    /// Convert a level's `size` into shares, using the portfolio as the base.
    ///
    /// The buy case is the interesting one. A plan step carries both what to do
    /// and where it lands you — `{"action": "+1/3", "after": "2/3"}` — so the
    /// rung you must currently be on is simply `after − action` = 1/3. That
    /// makes one unit equal to everything you presently hold, and "+1/3" means
    /// "buy that much again". No configuration, no guessing: it falls out of
    /// the plan's own arithmetic combined with the real position.
    ///
    /// Where the arithmetic bottoms out — an `entry` from nothing, whose implied
    /// current rung is 0 — there is no base and no honest answer, so it returns
    /// a reason instead of a number.
    static func instruction(for size: PositionChange?,
                            holding: HoldingPosition?,
                            price: Double?,
                            cash: Double?) -> ShareInstruction? {
        guard let size else { return nil }
        let action = TradeAction.parse(size.action)
        let held = holding?.shares ?? 0

        switch action {
        case .sellAll:
            guard held > 0 else { return ShareInstruction(shares: nil, isSell: true, note: "Not held") }
            return ShareInstruction(shares: Int(held), isSell: true)

        case .sellFractionOfHoldings(let f):
            guard held > 0 else { return ShareInstruction(shares: nil, isSell: true, note: "Not held") }
            // Round down: selling fewer shares than planned leaves you with a
            // position, selling more than you own is not a thing.
            return ShareInstruction(shares: Int((held * f).rounded(.down)), isSell: true)

        case .addFraction(let add):
            guard let after = TradeAction.fraction(in: size.after ?? "") else {
                return ShareInstruction(shares: nil, isSell: false, note: "Cannot derive — size.after missing")
            }
            // `after − action` is the rung you must be standing on for this step
            // to make sense. Zero means this is the opening tranche, which has
            // no prior holding to scale from.
            let currentRung = after - add
            guard currentRung > 0 else {
                return ShareInstruction(
                    shares: nil, isSell: false,
                    note: held > 0 ? "Already held — this step is done"
                            : "Opening tranche — no prior position to scale from")
            }
            guard held > 0 else {
                return ShareInstruction(shares: nil, isSell: false,
                                        note: "Not held — cannot infer a full position")
            }
            let unit = held / currentRung            // shares per 1.0 of position
            let buy = Int((unit * add).rounded(.down))
            var out = ShareInstruction(shares: buy, isSell: false)
            if let price, price > 0, let cash {
                out.affordableShares = Int((cash / price).rounded(.down))
            }
            return out

        case .buyBackToPrior:
            return ShareInstruction(shares: nil, isSell: false, note: "Buy back to the prior level")

        case .unrecognized:
            return nil
        }
    }

    /// Resolve every level of one stock together, so the sell ladder cascades.
    ///
    /// Each exit is written as a fraction *of holdings at that moment*, and the
    /// plan walks them in order: 減碼 → 減倉 → 停損. Sizing each one against
    /// today's position instead of the running remainder is wrong in a way that
    /// matters — for 36 shares it reports 18 / 18 / 36 when the truth is
    /// 18 / 9 / 9, and the last number tells you to sell four times what you
    /// would still own. Buys don't chain this way: each derives its own base
    /// from the rung it starts on.
    static func instructions(levels: [String: PlanLevel],
                             order: [String],
                             holding: HoldingPosition?,
                             price: Double?,
                             cash: Double?) -> [String: ShareInstruction] {
        var out: [String: ShareInstruction] = [:]
        var remaining = holding?.shares ?? 0

        for kind in order {
            guard let level = levels[kind] else { continue }
            let action = TradeAction.parse(level.size?.action)

            switch action {
            case .sellAll, .sellFractionOfHoldings:
                // Feed the running remainder in, not the original position.
                var stub = holding
                stub?.shares = remaining
                guard let instruction = instruction(for: level.size, holding: stub,
                                                    price: price, cash: cash) else { continue }
                out[kind] = instruction
                if let sold = instruction.shares { remaining = max(0, remaining - Double(sold)) }
            default:
                if let instruction = instruction(for: level.size, holding: holding,
                                                 price: price, cash: cash) {
                    out[kind] = instruction
                }
            }
        }
        return out
    }

    /// "18 sh" / "36 sh (cash covers 20)".
    static func describe(_ instruction: ShareInstruction?) -> String? {
        guard let instruction else { return nil }
        guard let shares = instruction.shares else { return instruction.note }
        var text = "\(shares) sh"
        if instruction.isShort, let affordable = instruction.affordableShares {
            text += " (cash covers \(affordable))"
        }
        return text
    }
}
